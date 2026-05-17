# CODEX TASK 10 — Universal municipal-program agent, source modes, multi-agent verification

## Goal

Turn the current MVP into a more universal and safer system that can work with municipal programs from different municipalities/regions, not only the current Shatura/Moscow Oblast document format.

The system must preserve the current successful corrections from TASK 09, but add:

1. explicit change-source mode: Excel target model OR PDF patch model OR Excel with PDF evidence;
2. adaptive municipal document profile for each organization/program;
3. dynamic funding-source aliases instead of Moscow-only hardcoded labels;
4. full target-model reconciliation for Excel, including zero rows and baseline objects absent from Excel;
5. independent multi-agent / multi-pass verification layer;
6. stricter export blocking when parser/matcher coverage is insufficient;
7. regression/golden tests on real documents and synthetic non-Moscow municipality fixtures.

The user-facing behavior remains Russian. The user must not manually confirm 50 rows. The agent resolves what can be resolved, blocks unsafe output, explains the blocker, and gives a ready DOCX only after all checks pass.

---

## Current code review findings

### What is now good

- TASK 09 fixed the biggest financial bug: Excel is no longer treated as just a list of additions for matched objects.
- `ExternalFinancialTargetValidator` now compares exported DOCX against Excel passport totals and source totals.
- Bad generated DOCX from `changeset-195-version-3.docx` is now expected to fail validation.
- `UNASSIGNED_RESIDUAL` is no longer inserted as a normal object.
- The procedure PDF is separated from change-source documents in the prompt and document types.
- `AgentWorkflowRunner`, `AgentToolRegistry`, background tasks, compact memory, and post-export validation already exist.

### What is still risky

1. **Source selection is not explicit enough.**
   `AgentToolRegistry#parsed_change_sources` currently selects latest Excel plus all PDF agreements automatically. For the real business process the user often works from either Excel OR PDF. If both are present, the system must not accidentally combine them unless the selected source mode says so.

2. **Excel target model is still incomplete.**
   TASK 09 creates zeroing only for an object that is matched to an Excel group. It does not yet implement full target reconciliation for:
   - objects present in DOCX but completely absent from Excel;
   - objects present in Excel with all zero amounts;
   - object rows retained in Excel but with no non-zero funding cells.

3. **The parser is format-specific.**
   `docx_parser.py` assumes finance table layout: display number in column 0, name in column 1, period in column 2, source in column 3, year columns after column 5. This can break on another municipality.

4. **Budget-source normalization is Moscow-centric.**
   `BudgetSource.MOSCOW_OBLAST_BUDGET` is not universal. Other regions may use regional, republican, krai, district, settlement, federal, local, extrabudgetary, own funds, concession/private funding, etc.

5. **Autonomous resolver is deterministic only.**
   The current `AgentAutonomousResolver` does not actually call an LLM semantic matcher, even though the agent prompt says it may use LLM semantic matching. This is okay for exact cases, but weak for other municipalities with different wording.

6. **Validation is strong at passport level, but not yet complete at leaf level.**
   The exported DOCX must be validated not only by passport totals, but also by object/source/year ledger coverage against the selected external source mode.

7. **No document-profile onboarding.**
   For universal use, the system needs to learn each municipality's DOCX/XLSX structure once and store a profile: hierarchy labels, table coordinates, source aliases, units, year columns, object-code patterns, residual handling, and export rules.

---

## Required architecture upgrade

Implement an explicit pipeline similar to a multi-node workflow:

```text
User chat / quick action
  -> Agent Planner
  -> Workspace State Check
  -> Document Profile Builder / Loader
  -> Source Mode Resolver
  -> Parser / Extractor
  -> Matcher Agent
  -> Target Model Builder
  -> Calculator / Tree Recalculator
  -> Independent Verifier Agent
  -> DOCX Patcher
  -> Post-export Validator
  -> Final Answer Composer
```

The LLM coordinates, explains, and performs semantic classification/matching where needed. It must not be the final calculator. All final amounts still come from deterministic decimal tools.

---

## 1. Add explicit source mode

### New concept

Add `source_mode` to `analysis_sessions.summary` and/or a new column if preferred.

Allowed values:

```text
excel_target
pdf_patch
excel_target_with_pdf_evidence
```

Meaning:

- `excel_target`: use the latest selected Excel as the full target financial model. Ignore PDF agreements for applying amounts. PDF may be visible in the workspace, but not part of the calculation.
- `pdf_patch`: use selected PDF agreements as partial amendments to the current DOCX. Do not perform Excel-style zeroing. Ignore Excel even if one is uploaded.
- `excel_target_with_pdf_evidence`: Excel is still the target model. PDF can support/explain changes. If PDF conflicts with Excel, Excel wins by default unless organization policy says otherwise, and the discrepancy goes to report.

### Default behavior

If only Excel is loaded:

```text
source_mode = excel_target
```

If only PDF agreements are loaded:

```text
source_mode = pdf_patch
```

If Excel and PDFs are both loaded:

```text
source_mode = organization.settings["default_source_mode"] || "excel_target_with_pdf_evidence"
```

Do not silently apply both as independent change sources unless mode is `excel_target_with_pdf_evidence`, and even then Excel is the final target.

### Code changes

Update:

- `AgentToolRegistry#parsed_change_sources`
- `AnalysisSessionRunner#selected_source_documents`
- `SourceConflictDetector`
- `PostExportDocxValidator`
- agent chat response around source choice
- UI/workspace context panel

Add tests:

- only Excel -> selected IDs include only Excel;
- only PDF -> selected IDs include PDFs only;
- Excel + PDF default -> Excel target, PDFs evidence;
- user says "используй только PDF" -> `pdf_patch` and Excel ignored;
- user says "используй Excel" -> `excel_target` or `excel_target_with_pdf_evidence` according to loaded PDFs.

---

## 2. Build `MunicipalDocumentProfile`

Create a new persisted model:

```ruby
MunicipalDocumentProfile
  organization_id
  municipal_program_id nullable
  status: draft/active/failed
  profile_type: docx_program/xlsx_finance/procedure
  source_document_id
  schema_json jsonb
  confidence decimal
  warnings jsonb
```

The profile should store municipality-specific extraction settings:

```json
{
  "program_structure": {
    "hierarchy_order": ["program", "subprogram", "main_activity", "activity", "object", "funding_line"],
    "subprogram_markers": ["Подпрограмма"],
    "main_activity_markers": ["Основное мероприятие"],
    "activity_markers": ["Мероприятие"],
    "total_markers": ["Итого", "Всего"]
  },
  "docx_finance_tables": [
    {
      "table_index": 6,
      "header_rows": [0, 1],
      "display_number_col": 0,
      "name_col": 1,
      "period_col": 2,
      "source_col": 3,
      "total_col": 4,
      "year_cols": {"2026": 5, "2027": 6, "2028": 7}
    }
  ],
  "passport_table": {
    "table_index": 1,
    "source_col": 0,
    "total_col": 1,
    "year_cols": {"2026": 2, "2027": 3, "2028": 4}
  },
  "excel_schema": {
    "sheet_name": "Результат",
    "header_rows": [7, 8],
    "object_code_col": "...",
    "object_name_col": "...",
    "activity_code_col": "...",
    "amount_columns": []
  },
  "units": {
    "docx_finance": "thousand_rub",
    "docx_passport": "thousand_rub",
    "xlsx": "rub"
  },
  "object_code_patterns": ["\\d{10}\\.\\d{10}"],
  "funding_source_aliases": {}
}
```

### Profile builder

Add service:

```ruby
DocumentProfileBuilder
```

It should:

1. inspect DOCX tables;
2. identify passport table;
3. identify finance tables;
4. identify year columns and total columns;
5. infer hierarchy columns;
6. infer source column and funding-source aliases;
7. store warnings when confidence is low.

The existing parser heuristics can remain as fallback, but production parsing should use the profile when available.

### User-facing behavior

If profile confidence is low, agent should say in Russian:

> Я не могу безопасно разобрать структуру этой программы: не нашел таблицу финансирования/колонки годов/источники. Финальный DOCX не формирую. Нужно уточнить структуру документа или загрузить другой формат.

No silent export.

---

## 3. Replace Moscow-only budget source model with dynamic aliases

Current code has:

```python
MOSCOW_OBLAST_BUDGET
MOSCOW_CITY_BUDGET
LOCAL_BUDGET
```

For universal use, add canonical source categories:

```text
FEDERAL_BUDGET
REGIONAL_BUDGET
LOCAL_BUDGET
MUNICIPAL_BUDGET
EXTRABUDGETARY
PRIVATE_FUNDS
OTHER_SOURCE
UNKNOWN
```

Keep old constants as aliases for backward compatibility, but internally normalize:

```text
MOSCOW_OBLAST_BUDGET -> REGIONAL_BUDGET
MOSCOW_CITY_BUDGET -> REGIONAL_BUDGET or CITY_BUDGET if explicitly configured
```

Add organization-specific aliases:

```ruby
FundingSourceAlias
  organization_id
  canonical_key
  label
  aliases jsonb
  sort_order
```

Examples:

```json
{
  "REGIONAL_BUDGET": [
    "бюджет московской области",
    "областной бюджет",
    "бюджет субъекта",
    "краевой бюджет",
    "республиканский бюджет",
    "бюджет ленинградской области"
  ],
  "LOCAL_BUDGET": [
    "местный бюджет",
    "бюджет муниципального округа",
    "бюджет городского округа",
    "средства бюджета муниципального образования"
  ]
}
```

Parser must return canonical key + original label:

```json
{
  "source_type": "REGIONAL_BUDGET",
  "source_label_raw": "Средства бюджета Московской области",
  "source_label_display": "Средства бюджета Московской области"
}
```

DOCX patcher should preserve original displayed labels from the source document whenever possible.

---

## 4. Full Excel target model reconciliation

This is critical for exactness.

Add service:

```ruby
ExternalTargetModelBuilder
```

For `excel_target` mode it must build a complete target ledger:

```text
target_key = [object_identity, parent_activity_code, year, source_type]
amount_rub
source_document_id
row_number
source_evidence
```

### Requirements

1. Keep Excel object rows even if all funding cells are zero.
   - Modify `excel_parser.py`: do not drop object groups just because funding is empty.
   - Add `explicit_zero_target: true` when the object row exists but all amount cells are zero/blank and the row is a valid object row.

2. If a DOCX object can be matched to an Excel object and Excel has no amount for a prior DOCX key, create zeroing.

3. If a DOCX object is absent from Excel entirely, do not assume one universal behavior. Use a policy:

```text
excel_absence_policy = block | zero_if_program_total_requires | leave_unchanged
```

Default for consolidated finance reports should be:

```text
zero_if_program_total_requires
```

Meaning:

- First build expected passport totals from Excel.
- Try target model with only matched objects.
- If totals do not match, solve missing/removal candidates.
- If a DOCX-only object must be removed/zeroed to match Excel totals and it has no evidence in Excel, mark as `agent_resolved_zeroing_by_target_total` only if uniqueness is mathematically proven.
- If multiple combinations could explain the gap, block export and explain unresolved coverage.

4. Validate coverage:

```text
excel_object_rows_total
excel_object_rows_matched
excel_object_rows_unmatched
baseline_objects_total
baseline_objects_matched_to_excel
baseline_objects_absent_from_excel
coverage_percent
```

If coverage is below configured threshold, do not export final DOCX.

Recommended default:

```text
required_excel_coverage_percent = 0.985
```

For the current Shatura case, set a golden regression target based on the correct May DOCX.

---

## 5. PDF patch ledger mode

For `pdf_patch` mode, PDF is not a full financial model. It is a patch document.

Add:

```ruby
PdfPatchLedgerBuilder
PdfPatchLedgerValidator
```

Expected behavior:

```text
baseline DOCX ledger
+ parsed PDF changes/deltas/transfers/zeroing
= expected target ledger
```

After exported DOCX is parsed, compare it with this expected target ledger.

Handle modes:

```text
absolute      -> set amount to value
increase      -> old + delta
reduce        -> old - delta
transfer      -> old year - amount, new year + amount
zeroing       -> set amount to 0
unknown       -> unresolved, do not apply
```

OCR PDF changes should require stronger evidence:

- object name or code;
- year;
- source;
- amount;
- page number/excerpt;
- if one of these is missing, do not apply silently.

---

## 6. Multi-agent / multi-pass quality layer

Add a clear separation of internal agent roles. These can be services, not separate UI agents.

### 6.1 Planner Agent

Existing `AgentWorkflowRunner` can play this role, but add structured plan output:

```json
{
  "source_mode": "excel_target",
  "steps": ["load_profile", "parse", "match", "build_target", "recalculate", "validate", "export"],
  "missing_inputs": [],
  "risk_level": "normal"
}
```

### 6.2 Matcher Agent

Add `SemanticMatchAgent` using OpenRouter primary model only when deterministic matching is insufficient.

Input must be bounded and safe:

```json
{
  "external_row": {"object_name": "...", "code": "...", "parent_activity": "..."},
  "candidate_program_nodes": [top 5 only],
  "allowed_actions": ["match_existing", "new_object", "residual_to_parent", "reject_unresolved"]
}
```

Output JSON:

```json
{
  "action": "match_existing",
  "program_node_id": 123,
  "reason": "...",
  "evidence": ["same object code", "same parent activity", "same year/source"],
  "risk_flags": []
}
```

Hard rules:

- LLM cannot output amounts.
- LLM cannot invent object IDs not in candidate list.
- Any semantic match must be verified by control sums.
- High-impact matches must go to reviewer.

### 6.3 Calculator Agent

This is deterministic code, not LLM:

```ruby
BudgetTreeCalculator
```

Responsibilities:

- build leaf ledger;
- aggregate object -> activity -> main activity -> subprogram -> program;
- compute row totals and passport totals;
- use BigDecimal only;
- produce an audit trail of formulas.

### 6.4 Verifier Agent

Add `IndependentVerifierAgent`.

It must not trust the model used by the matcher. It validates the result from scratch:

1. parse generated DOCX;
2. compare passport totals against selected target model;
3. compare leaf/object ledger against selected target model where possible;
4. check total columns;
5. check duplicate object groups;
6. check unknown sources;
7. check unresolved rows;
8. check document render;
9. produce `passed / blocked / warning`.

### 6.5 Reviewer Agent / Red-team pass

Optional but recommended: a second LLM pass for high-risk items only.

Use a different model if configured:

```text
primary_model: deepseek/deepseek-v4-pro
review_model: anthropic/claude-sonnet-4.5 or another strong model via OpenRouter
```

The reviewer receives:

- external row;
- selected match;
- top alternative candidates;
- evidence;
- control-sum impact;
- not the whole document.

It outputs:

```json
{ "verdict": "approve|reject|needs_block", "reason": "..." }
```

If reviewer rejects, block or retry.

---

## 7. Universal extraction strategy

### Parser must return diagnostics

Every parser output should include:

```json
{
  "parse_diagnostics": {
    "tables_seen": 42,
    "finance_tables_detected": 8,
    "passport_detected": true,
    "year_columns_detected": [2026, 2027, 2028],
    "funding_source_aliases_detected": [...],
    "unknown_source_rows": 3,
    "unparsed_finance_rows": 5,
    "coverage_score": 0.97,
    "warnings": []
  }
}
```

If diagnostics are weak, export is blocked.

### Parser must be profile-driven

- First try stored profile.
- If no profile, infer profile.
- If inferred profile confidence is high, store it.
- If low, ask user/admin to review profile or block export.

### Avoid exact Moscow-specific assumptions

Do not rely only on:

```python
row[0] = display number
row[1] = name
row[2] = period
row[3] = source
```

Instead infer columns from headers and table patterns.

---

## 8. UI / chat changes

### Source mode control

In `Документы` / workspace panel, show:

```text
Режим источника изменений:
[ Excel как целевая модель ] [ PDF как частичные изменения ] [ Excel + PDF как подтверждение ]
```

The agent can also set it through chat:

- "используй Excel" -> `excel_target`
- "используй только PDF" -> `pdf_patch`
- "Excel главный, PDF только для проверки" -> `excel_target_with_pdf_evidence`

### Agent response

If both Excel and PDF are loaded, agent must not say they conflict with the procedure PDF. The procedure PDF is only knowledge base.

Good response:

> Вижу Excel и PDF-основания. По умолчанию буду использовать Excel как итоговую финансовую модель, а PDF — как пояснение/подтверждение. Если нужно работать только по PDF, напишите: «используй только PDF».

### No manual row confirmation

Keep admin/debug pages if useful, but user flow must not require pressing row confirmations. Replace “Подтвердить строку” language in main UX with:

- “Агент разобрал”
- “Не хватает основания”
- “Исключено из применения”
- “Заблокировано до уточнения документов”

---

## 9. Regression tests and acceptance criteria

### Golden dataset tests

Add fixture pack:

```text
fixtures/golden/shatura_march.docx
fixtures/golden/shatura_finance.xlsx
fixtures/golden/shatura_may_expected.docx
fixtures/golden/procedure.pdf
```

Test:

```ruby
agent generates DOCX matching golden May document by passport totals, source totals, row total columns, and object ledger within tolerance
```

### Synthetic non-Moscow municipality tests

Add at least three synthetic packs:

1. Oblast/krai/republic regional source labels.
2. DOCX with year columns shifted or total column after years.
3. Excel with object row containing explicit zeros.
4. PDF-only patch with transfer and zeroing.

### Blocking tests

- Unknown finance table layout -> export blocked.
- Unknown source labels -> export blocked or alias setup required.
- Excel target totals do not match generated DOCX -> export blocked.
- Generated DOCX validates against internal model but fails Excel -> export blocked.
- LLM semantic match selects node but control sums fail -> rejected.

### Acceptance criteria

The project is not ready for universal demo until:

1. source mode is explicit and tested;
2. `BudgetSource` supports regional/local aliases dynamically;
3. Excel full target model handles explicit zero rows and absence policy;
4. generated DOCX is validated at passport + source + object ledger level;
5. SemanticMatchAgent exists for ambiguous row matching;
6. IndependentVerifierAgent blocks unsafe outputs;
7. Shatura golden test passes;
8. at least 3 non-Moscow synthetic municipality tests pass;
9. user chat never exposes internal service/class names.

---

## Suggested implementation order

### Iteration A — Source mode + no accidental mixing

- Add `source_mode`.
- Fix source selection.
- Add UI selector and chat commands.
- Tests for Excel-only/PDF-only/combined.

### Iteration B — Dynamic funding sources

- Add source alias model/service.
- Replace Moscow-only canonical keys with universal canonical keys.
- Keep backwards compatibility.
- Tests with regional/krai/republic labels.

### Iteration C — Full Excel target ledger

- Keep zero object rows.
- Add `ExternalTargetModelBuilder`.
- Add absence policy and coverage metrics.
- Validate object ledger, not just passport.

### Iteration D — Document profile

- Add `MunicipalDocumentProfile`.
- Build profile from DOCX/XLSX.
- Use profile in parsers.
- Block low-confidence parse.

### Iteration E — Multi-agent verification

- Add `SemanticMatchAgent`.
- Add `IndependentVerifierAgent`.
- Add reviewer pass for high-impact/ambiguous matches.
- Add golden dataset tests.

---

## Important note

Do not promise universal correctness for arbitrary unknown municipal documents without profile and validation. The correct product behavior is:

```text
If the structure is recognized and validators pass -> produce final DOCX/report.
If the structure is not recognized or source coverage is insufficient -> block final export and explain exactly what is missing.
```

This is the only safe way to make the product universal without silently generating wrong municipal program amendments.
