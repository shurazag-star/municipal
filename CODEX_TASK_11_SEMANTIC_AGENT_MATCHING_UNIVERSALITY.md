# CODEX TASK 11 — Semantic Agent Matching and Universal Municipal Program Workflow

## Goal

Improve the existing Municipal Program Agent without breaking the working Excel/PDF logic from TASK 09.

The current system already has important foundations:

- DOCX municipal program parsing into a tree.
- XLSX finance report parsing.
- PDF agreement parsing with OCR fallback.
- Excel-as-target financial model for matched objects.
- PDF-as-partial-patch model.
- DOCX patching, report generation, post-export validation, and Excel target validation.
- User-facing chat and background workflow.

The next step is to make the agent genuinely useful for difficult matching cases and more universal across municipalities. The AI must participate in semantic matching and verification, while deterministic code still performs final money calculations and hard validation.

Do **not** rewrite the project. Add an agentic semantic layer around the existing deterministic pipeline.

---

## Critical non-negotiable rules

1. **Do not break TASK 09.**
   - Excel remains a target financial model when used as the selected source mode.
   - Excel target validation must remain active.
   - Bad historical DOCX files like the previous inflated `changeset-195-version-3.docx` must still fail validation.
   - Passport yearly totals, passport source totals, and passport `Всего` column must continue to be validated.

2. **Do not break PDF behavior.**
   - PDF agreement documents remain partial amendments, not full target models.
   - Transfer, delta plus, delta minus, absolute, and zeroing modes must keep working.
   - PDF OCR fallback must keep working.

3. **LLM must not be the final calculator.**
   - LLM may choose semantic matches, classify unclear rows, explain reasoning, and propose retries.
   - All monetary calculations, rollups, source/year totals, and final validation must be done by deterministic Ruby/Python code with exact decimal arithmetic.

4. **No manual row confirmation in the default workflow.**
   - The user should not be asked to confirm 50 rows manually.
   - The agent must resolve what it can, verify it, and block export only for genuinely unresolved or unsafe items.

5. **One user-facing agent, multiple internal roles.**
   - The UI should still show one agent.
   - Internally, implement sub-services/sub-agents: source planner, semantic matcher, independent verifier, report/explanation composer.

---

## Current code review findings

The current code is improved but still mainly deterministic:

- `ExternalSourceMatcher` matches by exact code, exact name, simple token overlap, and residual parent heuristics.
- `AgentAutonomousResolver` resolves rows mostly by rule checks: object exists, year/source present, parent code exists, amount changes.
- `AgentAnswerGenerator` uses OpenRouter for user-facing explanation.
- `AgentIntentRouter` uses OpenRouter for intent selection.
- There is **no real LLM semantic matching layer** for source rows that deterministic matching cannot confidently attach to a DOCX object.
- There is no persistent semantic decision ledger.
- There is no explicit `source_mode`; current analysis normally takes the latest Excel plus all parsed PDF agreements.
- Parser structure is still tied to fairly fixed DOCX/Excel table patterns.
- Budget sources are still Moscow-centric in several places (`MOSCOW_OBLAST_BUDGET`, `MOSCOW_CITY_BUDGET`). Keep compatibility but start adding universal aliasing.

This task should add the missing semantic matching and verification layer while keeping existing behavior safe.

---

## Part 1 — Add explicit source mode

### Add `source_mode` to analysis sessions

Add a migration:

```ruby
add_column :analysis_sessions, :source_mode, :string, null: false, default: "auto"
add_column :analysis_sessions, :source_policy, :jsonb, null: false, default: {}
```

Allowed source modes:

```text
auto
xlsx_target
pdf_patch
xlsx_target_with_pdf_evidence
```

Meaning:

- `xlsx_target`: use the latest selected/parsed Excel as the full financial target. Do not apply PDF changes on top.
- `pdf_patch`: use selected PDF agreements as partial amendments. Do not use Excel.
- `xlsx_target_with_pdf_evidence`: Excel is the financial target; PDF agreements are used only for evidence/conflict notes, not as additive patches unless the code explicitly proves they do not duplicate Excel.
- `auto`: resolve to one of the above based on uploaded sources.

### Default auto resolution

Implement `SourceModeResolver`:

```ruby
class SourceModeResolver
  def resolve(organization:, explicit_mode: nil, selected_documents: [])
  end
end
```

Rules:

- Only Excel present -> `xlsx_target`.
- Only PDF agreements present -> `pdf_patch`.
- Excel + PDF present -> `xlsx_target_with_pdf_evidence` by default.
- User says “работай только по PDF” -> `pdf_patch`.
- User says “используй Excel как основание / Excel главный” -> `xlsx_target` or `xlsx_target_with_pdf_evidence` depending on whether PDFs are present.

### Update source selection

Change `AgentToolRegistry#parsed_change_sources` and `AnalysisSessionRunner#selected_source_documents` so they honor `source_mode`.

Do not keep the old implicit behavior of always applying latest Excel plus all PDFs as actual changes.

Expected behavior:

```text
xlsx_target:
  selected docs = latest/selected xlsx_finance only

pdf_patch:
  selected docs = selected/all parsed pdf_agreement only

xlsx_target_with_pdf_evidence:
  selected docs = latest/selected xlsx_finance + PDFs as evidence
  ChangeSetBuilder must not double-apply PDF rows already represented by Excel target totals.
```

### Tests

Add tests for:

- only Excel -> `xlsx_target`;
- only PDF -> `pdf_patch`;
- Excel + PDF -> `xlsx_target_with_pdf_evidence`;
- user command “работай только по PDF” excludes Excel;
- user command “используй Excel” excludes PDF patches as additive changes;
- Excel target validation still runs for Excel modes;
- PDF-only mode does not require Excel target totals.

---

## Part 2 — Add SemanticMatchAgent

### Why

The current matcher is not enough for universal municipalities. Program code can miss cases where:

- object names differ slightly;
- ministry PDF uses short names;
- Excel object name differs from DOCX object wording;
- parent activity wording changed;
- object appears as address/name variant;
- residual/aggregate rows need semantic classification;
- new object should be inserted under a parent that has no exact code match.

The LLM should help here, but only as a semantic matcher, not as a calculator.

### Add model/table: `agent_match_decisions`

Migration:

```ruby
create_table :agent_match_decisions do |t|
  t.references :organization, null: false, foreign_key: true
  t.references :analysis_session, foreign_key: true
  t.references :source_document, foreign_key: true
  t.references :match_candidate, foreign_key: true
  t.references :change_item, foreign_key: true
  t.references :selected_program_node, foreign_key: { to_table: :program_nodes }
  t.string :decision_type, null: false
  t.decimal :confidence, precision: 5, scale: 4
  t.text :reason
  t.jsonb :input_snapshot, null: false, default: {}
  t.jsonb :candidate_snapshot, null: false, default: {}
  t.jsonb :llm_output, null: false, default: {}
  t.jsonb :validation_result, null: false, default: {}
  t.string :status, null: false, default: "created"
  t.string :model
  t.string :prompt_hash
  t.timestamps
end
```

Allowed `decision_type`:

```text
existing_object
new_object
residual_to_parent
aggregate_only
ignore_not_finance
needs_clarification
```

Allowed `status`:

```text
created
accepted
rejected
needs_clarification
failed
```

### Add candidate builder

Create `SemanticCandidateBuilder`.

Input:

- source row/group from Excel/PDF;
- current program version;
- match candidate/change item;
- source mode.

Output: top candidate program nodes.

Candidate sources:

- exact object code;
- exact normalized name;
- token overlap;
- parent activity code;
- same subprogram/activity path;
- year/source overlap;
- previous accepted `agent_match_decisions` in the same organization;
- existing object aliases from organization settings.

Return max 10 candidates. Include for each candidate:

```json
{
  "program_node_id": 123,
  "node_type": "object",
  "name": "...",
  "path": "program > subprogram > main activity > activity > object",
  "display_number": "...",
  "code": "...",
  "years": [2026, 2027],
  "sources": ["REGIONAL_BUDGET", "LOCAL_BUDGET"],
  "deterministic_score": 0.74,
  "why_candidate": ["same parent activity", "name overlap"]
}
```

### Add SemanticMatchAgent service

Create `SemanticMatchAgent` in Rails.

Input:

```ruby
SemanticMatchAgent.new(
  organization:,
  user:,
  analysis_session:,
  source_document:,
  match_candidate:,
  change_item:,
  source_mode:
).call
```

It should call OpenRouter with a strict JSON schema.

LLM system prompt must say:

- You are a semantic matching sub-agent.
- You do not calculate money.
- You choose where an already parsed external row belongs in the DOCX program tree.
- You must use only provided candidates and evidence.
- You must not invent program nodes, amounts, years, or sources.
- Return JSON only.

Expected JSON schema:

```json
{
  "decision_type": "existing_object | new_object | residual_to_parent | aggregate_only | ignore_not_finance | needs_clarification",
  "selected_program_node_id": 123,
  "confidence": 0.0,
  "reason": "short Russian reason for audit",
  "evidence": ["..."],
  "risks": ["..."]
}
```

Rules:

- For `existing_object`, `selected_program_node_id` must be one of the provided candidate IDs.
- For `residual_to_parent`, selected node must be an activity/main_activity/residual target that the code can validate.
- For `new_object`, require parent evidence: parent activity code, section path, or strong textual evidence.
- If the candidate list is weak or ambiguous, return `needs_clarification`.
- If row is an aggregate/total line, return `aggregate_only`.
- If row is not about program funding, return `ignore_not_finance`.

### Do not expose this to the user as raw JSON

Store decisions in `agent_match_decisions`. User-facing chat should receive only clean Russian explanations.

---

## Part 3 — Integrate SemanticMatchAgent without breaking deterministic matching

### Change matching pipeline

Keep existing deterministic matching first:

```text
ExternalSourceMatcher deterministic pass
  exact code
  exact name
  confident fuzzy
  residual parent heuristic
```

Then add semantic pass only for:

- `MISSING_IN_DOCX`;
- `NEEDS_CONFIRMATION`;
- low confidence fuzzy matches;
- ambiguous residual rows;
- new object candidates without fully trusted parent;
- PDF rows with `unknown` amount mode or OCR warnings.

Do not call LLM for already exact/high-confidence deterministic matches unless the user specifically asks to recheck one object.

### Apply accepted semantic decisions

Add service `SemanticMatchDecisionApplier`.

It should transform accepted decisions into safe match/change behavior:

- `existing_object`: attach source row/change item to selected existing object.
- `new_object`: keep as new object only if parent can be validated.
- `residual_to_parent`: attach to a safe residual/parent target only if deterministic rollup validation allows it.
- `aggregate_only`: reject/exclude the row from application but include it in the report as not applied because it is an aggregate.
- `ignore_not_finance`: reject/exclude.
- `needs_clarification`: leave unresolved and block final export.

### Required validation after every semantic decision

Before accepting an LLM decision, run deterministic validation:

- selected node belongs to the active program version;
- selected node type is allowed;
- year/source exist or are safely created;
- source mode permits this operation;
- no duplicate funding key is created unless it is a target replacement;
- for Excel target mode, passport/source totals still reconcile with Excel;
- for PDF patch mode, patch ledger still reconciles with baseline + patch;
- no numeric object names;
- no row is inserted under the wrong subprogram.

If validation fails, mark decision as `rejected` and either retry with expanded candidates or set the item to `needs_clarification`.

### Retry loop

For unresolved important rows:

1. Try deterministic match.
2. Try semantic match with top 10 candidates.
3. If invalid, retry once with expanded candidates/top 20 and more hierarchy context.
4. Run independent verification.
5. Accept only if code validation passes.
6. Otherwise block export with a human-readable reason.

Set a hard cap to avoid infinite loops.

---

## Part 4 — Add IndependentVerifierAgent

### Purpose

A second sub-agent checks risky semantic decisions. It is not the same as post-export validator.

It receives:

- source row/PDF evidence;
- selected program node/path;
- candidate alternatives;
- proposed decision;
- deterministic validation summary.

It returns JSON:

```json
{
  "verdict": "approve | reject | needs_clarification",
  "reason": "...",
  "risks": ["..."],
  "suggested_decision_type": "...",
  "suggested_program_node_id": 123
}
```

Use it only for risky decisions:

- LLM semantic matches;
- OCR PDF rows;
- transfers;
- zeroing;
- residual rows;
- new objects;
- conflicts between Excel and PDF;
- match confidence below threshold but above retry threshold.

Do not use verifier for obvious exact matches.

### Acceptance rule

A risky semantic decision can be applied only if:

```text
SemanticMatchAgent decision accepted
AND IndependentVerifierAgent approves or deterministic validator marks it low-risk
AND code-level financial validation passes
```

---

## Part 5 — Add PDF patch ledger validation

### Why

Excel has a full target validator. PDF does not. In PDF-only mode the system currently validates mainly against its internal target model. Add an independent patch ledger so the PDF flow is safer.

### Add `ExternalPatchLedgerBuilder`

For every PDF change item, store expected operation:

```json
{
  "source_document_id": 10,
  "change_item_id": 55,
  "object_name": "...",
  "program_node_id": 123,
  "year": 2027,
  "source_type": "REGIONAL_BUDGET",
  "amount_mode": "absolute | delta_plus | delta_minus | transfer | zeroing",
  "old_amount_rub": "...",
  "expected_new_amount_rub": "...",
  "delta_rub": "...",
  "evidence_text": "...",
  "page_number": 3
}
```

For transfer:

- create two ledger entries: minus from old year, plus to new year.

### Add `ExternalPatchLedgerValidator`

After DOCX export and re-parse:

- locate the affected object/path;
- verify expected year/source amount is present;
- verify delta operation was applied exactly;
- verify passport rollup changed consistently;
- verify no duplicate/unintended additional patch was applied.

For PDF-only mode, final DOCX can be valid only if patch ledger validation passes.

---

## Part 6 — Add targeted object recalculation from chat

The user must be able to write naturally:

```text
пересчитай Черусти
проверь объект ВЗУ Черусти
сформируй новую редакцию только по этому объекту
почему по нему изменилась сумма
перепроверь эту позицию
```

### Add intents

Extend `AgentIntentRouter::ALLOWED_INTENTS`:

```text
recheck_object
recalculate_object
explain_object_change
```

### Add tools

In `AgentToolRegistry` add:

```ruby
recheck_object(arguments)
recalculate_object(arguments)
```

Behavior:

- Resolve object query using current conversation memory and object names.
- Find related change items.
- If no change project exists, run analysis first but filter/report by object.
- Re-run deterministic + semantic matching for that object only.
- Recalculate affected node and ancestors.
- Return object-level before/after/delta by year/source.
- If user asks to form DOCX, continue through full validation and export.

### Memory

When an object is discussed, store:

```json
working_state.last_object_query
working_state.last_program_node_id
working_state.last_object_name
working_state.last_source_mode
```

Follow-up like “а по нему?” must refer to that object.

---

## Part 7 — Add MunicipalDocumentProfile as an adaptive layer

### Why

The current DOCX parser assumes fairly fixed table layouts. For other municipalities, layouts may shift. Add a profile so the system can adapt and can block export when it cannot prove the layout.

### Add model/table

```ruby
create_table :municipal_document_profiles do |t|
  t.references :organization, null: false, foreign_key: true
  t.references :source_document, foreign_key: true
  t.references :program_version, foreign_key: true
  t.string :profile_type, null: false
  t.string :status, null: false, default: "draft"
  t.decimal :confidence, precision: 5, scale: 4
  t.jsonb :payload, null: false, default: {}
  t.jsonb :issues, null: false, default: []
  t.timestamps
end
```

Profile payload should contain:

```json
{
  "passport_table": {"table_index": 0, "confidence": 0.96},
  "finance_tables": [
    {
      "table_index": 6,
      "subprogram_number": 1,
      "columns": {
        "display_number": 0,
        "name": 1,
        "period": 2,
        "source": 3,
        "total": 4,
        "years": {"2026": 5, "2027": 6}
      },
      "unit": "thousand_rub",
      "confidence": 0.94
    }
  ],
  "source_aliases_detected": {},
  "years": [2026, 2027, 2028, 2029, 2030],
  "money_unit": "thousand_rub"
}
```

### Profile builder

Create `MunicipalDocumentProfileBuilder`:

- First use deterministic heuristics already in `docx_parser.py` and `excel_parser.py`.
- If profile confidence is low, call `DocumentProfileAgent` with a compact table/header snapshot.
- Parser must still validate the LLM-suggested profile by reading actual cells and checking totals.

### Do not require perfect profile for existing current documents

The existing Shatura document must continue to parse exactly as before. The profile layer should wrap/record existing parse assumptions, not replace the parser in one step.

---

## Part 8 — Universal budget source aliases

Current source types still include Moscow-specific names. Do not break them, but add universal alias support.

### Keep backward compatibility

Keep existing enum values for now:

```text
FEDERAL_BUDGET
MOSCOW_OBLAST_BUDGET
MOSCOW_CITY_BUDGET
LOCAL_BUDGET
EXTRABUDGETARY
UNKNOWN
```

### Add generic category in metadata

Add helpers:

```ruby
BudgetSourceNormalizer.category_for(source_type)
```

Categories:

```text
FEDERAL
REGIONAL
MUNICIPAL
LOCAL
EXTRABUDGETARY
PRIVATE
OTHER
UNKNOWN
```

For other regions, `MOSCOW_OBLAST_BUDGET` can be displayed as “региональный бюджет” internally until a better enum migration is done.

### Use organization aliases

`organization.settings["source_aliases"]` already exists in admin controller. Use it in Rails normalization and reports.

Examples:

```json
{
  "областной бюджет": "REGIONAL",
  "краевой бюджет": "REGIONAL",
  "республиканский бюджет": "REGIONAL",
  "бюджет субъекта": "REGIONAL",
  "местный бюджет": "LOCAL",
  "средства инвестора": "PRIVATE"
}
```

For Python parsers, either:

- pass aliases through parser invocation, or
- return raw source labels and normalize them in Rails after parsing.

Choose the least disruptive route. Do not break existing tests.

---

## Part 9 — Chat and workflow behavior

The user-facing agent must behave like the main specialist.

### No technical leakage

Still avoid these words in the user chat:

```text
ChangeSet
parser
worker
intent
tool
JSON
post_export_validation
manual_insert_required
INSERTED_IN_DOCX
PROGRAM_TOTAL_DIFF
class names/service names
```

Use instead:

```text
проект изменений
разбор документов
сопоставление строк
проверка документа
контрольные суммы
готовая новая редакция
```

### Background workflow

Semantic matching can take time. Use existing `AgentTask`/`AgentTaskJob`.

Progress messages should be user-friendly:

```text
Изучаю документы-основания.
Сопоставляю строки Excel/PDF с объектами программы.
Проверяю спорные совпадения вторым проходом.
Пересчитываю суммы по дереву программы.
Проверяю Word-документ после формирования.
```

### Agent should not ask for row confirmation

If unresolved items remain, say:

```text
Я не могу выпустить финальный DOCX: 3 строки не удалось надежно связать с объектами программы. Показываю причины и какие данные нужны.
```

Not:

```text
Подтвердите строки 1, 2, 3.
```

---

## Part 10 — Tests and regression requirements

### Existing tests must continue to pass

Run:

```bash
docker-compose exec -T web bin/rails test
.venv/bin/python -m pytest parser_worker/tests
```

### Add new Rails tests

Add tests for:

1. Source mode resolver.
2. Excel-only mode.
3. PDF-only mode.
4. Excel + PDF evidence mode does not double apply PDF.
5. SemanticMatchAgent accepts only schema-valid JSON.
6. Semantic decision is rejected if selected node is not in candidate list.
7. Semantic decision is rejected if financial validation fails.
8. New object semantic decision requires a validated parent.
9. Aggregate-only semantic decision excludes row and reports it.
10. Recheck object chat command finds object and returns object-level amounts.
11. Follow-up “по нему” uses conversation memory.
12. PDF patch ledger validates transfer as two operations.
13. Existing TASK 09 regression: bad inflated DOCX still fails Excel external validation.
14. Golden test: March DOCX + Excel must produce passport totals matching the correct May DOCX within tolerance.

### Add parser/profile tests

Add tests for:

- DOCX profile extraction on current real document.
- Synthetic DOCX with shifted source/year columns.
- Excel with zero rows preserved as target information.
- Alternative budget source labels: краевой бюджет, бюджет субъекта РФ, местный бюджет, внебюджетные средства.

---

## Implementation order

Do this in safe stages:

### Implementation progress

- [x] Task file copied into project root on 2026-05-16.
- [x] Stage 1 — Source mode only.
- [x] Stage 2 — Semantic decision ledger and candidate builder.
- [x] Stage 3 — SemanticMatchAgent.
- [x] Stage 4 — Decision applier and independent verifier.
- [x] Stage 5 — PDF patch ledger.
- [x] Stage 6 — Targeted object recalculation chat.
- [x] Stage 7 — Document profile layer.
- [x] Regression tests and documentation.

### Stage 1 — Source mode only

- Add `source_mode` and `SourceModeResolver`.
- Update selected source documents.
- Add tests.
- Do not add LLM semantic matching yet.

### Stage 2 — Semantic decision ledger and candidate builder

- Add `agent_match_decisions`.
- Add `SemanticCandidateBuilder`.
- Add tests for candidate selection.

### Stage 3 — SemanticMatchAgent

- Add LLM structured JSON call.
- Add schema validation and sanitization.
- Store decision ledger.
- Do not apply decisions until deterministic validation passes.

### Stage 4 — Decision applier and independent verifier

- Apply accepted semantic decisions.
- Add `IndependentVerifierAgent` for risky decisions.
- Add retry loop.

### Stage 5 — PDF patch ledger

- Add `ExternalPatchLedgerBuilder` and validator.
- Integrate with post-export validation for PDF-only mode.

### Stage 6 — Targeted object recalculation chat

- Add new intents and tools.
- Add memory state.
- Add integration tests.

### Stage 7 — Document profile layer

- Add `MunicipalDocumentProfile`.
- Record current parser assumptions as profile.
- Add optional LLM profile help for low-confidence layouts.
- Block export if profile confidence is too low and totals cannot be validated.

---

## Definition of done

This task is complete only if:

1. Current Excel and PDF flows still pass all existing tests.
2. Excel target mode still validates against Excel after export.
3. PDF patch mode has patch-ledger validation.
4. The system no longer applies latest Excel plus all PDF patches by accident.
5. Low-confidence/ambiguous rows can be routed through `SemanticMatchAgent`.
6. LLM decisions are saved in a ledger and validated before use.
7. A second verifier checks risky semantic decisions.
8. The user can ask in chat to recheck/recalculate a concrete object.
9. Final DOCX is offered only after deterministic validation passes.
10. Unresolved rows block export with a clear Russian explanation, not manual row confirmation.
11. Existing real-document regression from TASK 09 remains green.
12. README, `агент.md`, and WORKLOG are updated with the new architecture and limitations.
