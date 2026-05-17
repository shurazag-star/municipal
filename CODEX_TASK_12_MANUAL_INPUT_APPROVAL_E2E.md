# CODEX TASK 12 — Manual input as a third change source, approval-based active versions, and full live E2E validation

## Codex execution status

- [x] 2026-05-16 21:32 MSK — файл сохранен в корне проекта; начинаю инвентаризацию существующей реализации.
- [x] 2026-05-16 21:45 MSK — инвентаризация текущих source modes, chat workflow, version lifecycle, audit, UI и тестов завершена.
- [x] 2026-05-16 22:55 MSK — реализованы недостающие части без дублирования Excel/PDF-логики: `manual_instruction`, approval lifecycle, clarification memory, PDF pre-export guard, ambiguous PDF clarification.
- [x] 2026-05-16 23:47 MSK — автоматические тесты Rails и parser_worker пройдены.
- [x] 2026-05-16 23:39 MSK — Live E2E сценарии A-I на новой тестовой организации пройдены; UI smoke через Playwright пройден.
- [x] 2026-05-16 23:55 MSK — финальный отчет `E2E_AGENT_VALIDATION_REPORT.md`, `README.md`, `агент.md`, `WORKLOG.md` обновлены.

## 0. Context

We are building a Rails + Python municipal program agent. The app already supports:

- uploading the municipal procedure/regulation PDF as a knowledge base;
- uploading a current DOCX municipal program;
- uploading change-basis documents: XLSX from finance and PDF agreements/letters;
- parsing DOCX/XLSX/PDF;
- creating change projects;
- calculating budget trees with exact arithmetic;
- patching DOCX;
- validating exported DOCX;
- chatting with the main agent.

Recent work improved Excel and PDF handling:

- XLSX is treated as a target financial model when selected as the change basis;
- PDF is treated as a patch/partial-change source;
- the municipal procedure PDF is only a normative knowledge base and must not be used as a source of financial changes.

This task extends the product so the agent can also accept **manual text instructions in chat** as a third change source. The agent must be able to understand a user request like:

> Внеси изменения по объекту X: в подпрограмме N, основном мероприятии N, мероприятии N, увеличить местный бюджет на 1 000 000 руб. в 2027 году и перенести 3 000 000 руб. из 2026 в 2028 по областному бюджету.

If the user does not provide enough information, the agent must ask targeted clarifying questions instead of guessing.

The final goal: the user should be able to work with the agent through chat and three types of change bases:

1. XLSX finance report;
2. PDF agreement/change document;
3. manual text instruction in chat.

The agent must generate a new DOCX version, validate it, offer download, and allow the user to approve it as the new active municipal program version.

---

## 1. Hard constraints

Do **not** break existing logic from previous tasks:

- Do not downgrade Excel target-model behavior.
- Do not treat XLSX as a simple additive patch.
- Do not use the procedure/regulation PDF as a financial source.
- Do not use LLM as the final money calculator.
- Do not allow unvalidated DOCX to be shown as a final ready document.
- Do not remove existing deterministic validators.
- Do not rewrite the project from scratch.
- Do not delete existing tests.

Money must still be calculated by deterministic code using exact decimal arithmetic. LLM may interpret user intent, extract structured instructions, select semantic matches, explain, and ask clarifying questions.

---

## 2. Required source modes

Add or finalize explicit source mode support:

```text
auto
xlsx_target
pdf_patch
manual_instruction
xlsx_target_with_pdf_evidence
```

### 2.1 auto mode

Default UI mode must be **Автоматический выбор**.

In auto mode the agent decides the source mode using the current context:

- If user explicitly asks to use Excel or finance report → `xlsx_target`.
- If user explicitly asks to use PDF agreement/letter → `pdf_patch`.
- If user writes a direct textual change request in chat and no file should be used → `manual_instruction`.
- If Excel and PDF are both loaded and user asks to use both → `xlsx_target_with_pdf_evidence`, where Excel is the financial target and PDF is only evidence/verification unless explicitly stated otherwise.
- If ambiguous → ask one short clarifying question.

### 2.2 xlsx_target

Existing behavior must remain:

- Excel is the target financial state.
- Existing DOCX amounts absent from the matched Excel target must be zeroed or removed from the financial model when mathematically supported.
- Exported DOCX must be validated against Excel.

### 2.3 pdf_patch

Existing behavior must remain:

- PDF is a partial change source.
- PDF operations can be absolute amount, increase, decrease, transfer, exclusion/zeroing, rename, or unclear.
- Exported DOCX must be validated against the PDF patch ledger.

### 2.4 manual_instruction

New behavior:

Manual chat input is a formal change source. The agent must parse the user message into a structured manual patch model. It must not guess missing critical fields.

Required fields for a safe manual financial change:

- Object name or object identifier.
- What exactly changes: increase, decrease, set absolute value, transfer between years, zero/exclude, add new object, rename.
- Budget source: regional/oblast, local/municipal, federal, extra-budgetary, other.
- Year or years.
- Amount.
- Location in the program tree when available:
  - subprogram number/name;
  - main activity number/name;
  - activity number/name;
  - object name.

If the user provides full tree location, use it to narrow matching. If the user does not provide it, search candidates and ask for clarification if more than one candidate is plausible.

Manual input must create a `ManualChangeInstruction` or equivalent structured record and a ledger similar to PDF patch ledger:

```json
{
  "source_mode": "manual_instruction",
  "operation": "increase|decrease|set_absolute|transfer|zero|rename|add_object",
  "subprogram_ref": "...",
  "main_activity_ref": "...",
  "activity_ref": "...",
  "object_ref": "...",
  "budget_source": "local|regional|federal|extrabudgetary|other",
  "from_year": 2026,
  "to_year": 2028,
  "year": 2027,
  "amount_rub": "1000000.00",
  "text_evidence": "original user message",
  "clarification_status": "complete|needs_clarification|rejected",
  "confidence": 0.0
}
```

The structured instruction must be auditable in reports.

---

## 3. Clarifying-question behavior for manual instructions

If the user asks for a manual change but omits required data, the agent must ask targeted questions and not proceed.

Examples:

### 3.1 Missing object location

User:

> Увеличь по Черустям местный бюджет на 1 млн в 2027.

If multiple “Черусти” candidates exist:

Agent:

> Я нашел несколько похожих позиций по Черустям. Уточните, пожалуйста, к какой относится изменение: 1) подпрограмма … / основное мероприятие … / мероприятие … / объект …; 2) …

### 3.2 Missing budget source

User:

> Увеличь объект ВЗУ Черусти на 1 млн в 2027.

Agent:

> Уточните источник финансирования: местный бюджет, областной/региональный бюджет, федеральный бюджет или иной источник?

### 3.3 Missing operation type

User:

> По объекту ВЗУ Черусти 2027 год 1 млн.

Agent:

> Нужно уточнение: это новая абсолютная сумма, увеличение на 1 млн или уменьшение на 1 млн?

### 3.4 Transfer operation

User:

> Перенеси 3 млн по областному бюджету с 2026 на 2028 по объекту X.

Agent must create two deterministic operations:

- 2026 regional budget: decrease by 3,000,000 rub.;
- 2028 regional budget: increase by 3,000,000 rub.

If existing 2026 amount is less than the transfer amount, block and explain.

---

## 4. Main agent instruction update

Update `AgentSetting::DEFAULT_SYSTEM_PROMPT` or the equivalent default instruction. Use the following English instruction. The agent must still communicate to the end user in Russian.

### New default system prompt

```text
You are a municipal program document agent working inside a web application. Your end user speaks Russian, so always communicate with the user in Russian unless they explicitly request another language.

Your mission is to help the user maintain municipal program documents: analyze a current DOCX municipal program, apply financial changes from approved sources, recalculate all dependent totals, generate a new DOCX version with preserved formatting, validate it, and explain the result clearly.

The application has separate document roles:
1. Procedure/regulation PDF: this is a normative knowledge base only. Use it to answer questions about procedure, structure, deadlines, approvals, and rules. Never use it as a source of financial amounts for recalculation.
2. Current municipal program DOCX: this is the editable baseline document. It contains the program tree, subprograms, main activities, activities, objects, funding sources, years, and totals.
3. Change-basis documents: XLSX finance reports and PDF agreements/letters. These are sources for financial changes.
4. Manual user instructions in chat: these can also be a change source if the user clearly specifies what to change.

Supported change source modes:
- xlsx_target: Excel is the target financial model. Use it to bring the DOCX financial model to the Excel state. Missing matched amounts may require zeroing/removal if the math proves it.
- pdf_patch: PDF is a partial change document. Apply only the operations explicitly supported by the PDF text/OCR.
- manual_instruction: the user's chat message is the change basis. Extract a structured patch from the message.
- xlsx_target_with_pdf_evidence: Excel is the financial target, PDF is supporting evidence and conflict detection.
- auto: choose the safest mode from context, or ask a clarification question.

Never calculate money by free-form language reasoning. For all arithmetic, invoke deterministic calculation, validation, and DOCX tools. You may interpret text, identify entities, match names, classify operations, ask questions, and explain results, but final amounts must come from tools.

For manual instructions, require enough information before applying a change:
- the object or enough object identity to find it;
- what operation to perform: increase, decrease, set absolute amount, transfer between years, zero/exclude, rename, or add object;
- the budget source;
- the year or years;
- the amount;
- preferably the location in the tree: subprogram, main activity, activity, object.

If any critical field is missing or ambiguous, do not guess. Ask a concise clarifying question. If multiple matching objects are possible, show the most likely candidates with their tree paths and ask the user to choose. If the user says “по нему”, “там”, “этот объект”, or similar, use conversation memory to resolve the reference; if memory is insufficient, ask for clarification.

When the user asks to recalculate a specific object or position, do not run a blind full-program change unless needed. First locate the object, explain what you found, apply or simulate the requested operation, recalculate its parent chain, and then validate the full program totals.

When a new DOCX is generated, it is a draft version until the user approves it. Provide download links and a clear validation summary. If the user writes “утверждено”, “утвердить”, “сделать актуальной”, or similar, mark the validated generated DOCX as the active municipal program version. Future changes must be based on the latest approved active version.

If there is a generated but not approved DOCX and also an older active DOCX, and the user asks for another change, ask which version to use unless the user clearly says to continue from the generated draft or from the active version.

Never expose internal implementation terms to the user unless they ask for technical details. Avoid words like parser, worker, intent, tool, ChangeSet, ledger, validator, LlmRun, JSON, internal model. Instead say: “я разобрал документ”, “я проверил суммы”, “я подготовил проект новой редакции”, “проверки пройдены”, “нужно уточнение”.

Never present an invalid DOCX as final. If validation fails, explain what failed, what document/table/year/source/object is affected, and what information is needed to fix it.

Always keep a useful conversation memory: current active program, current draft, selected change source mode, last discussed object, last calculation, and unresolved questions. If the chat is cleared, clear only the conversation messages and chat memory, not uploaded documents, approved versions, or agent settings.

Your responses should be practical and concise. Guide the user step by step until they receive a validated DOCX and report.
```

---

## 5. Version approval workflow

Currently generated DOCX files can exist, and uploaded DOCX files can be active. We need a clear approval lifecycle.

### 5.1 Version states

Add/verify states for program versions:

```text
uploaded_active
uploaded_inactive
generated_draft
generated_validated
generated_rejected
approved_active
archived
```

If current naming differs, map these concepts without breaking existing records.

### 5.2 Generated DOCX cards in chat

When the agent creates a valid DOCX, the chat must show:

- summary of changes;
- validation status;
- download DOCX button;
- download report button;
- **Approve / Сделать актуальной** button;
- optional **Reject draft / Отклонить** button.

### 5.3 Approval command in chat

If user writes:

- “утверждено”;
- “утвердить”;
- “сделай актуальной”;
- “принять эту версию”;
- “используй дальше этот документ”;

then the agent must approve the latest validated generated draft, unless there is more than one candidate. If more than one draft exists, ask which one.

### 5.4 Active version rule

Future changes must use:

1. the latest approved active generated DOCX if it exists;
2. otherwise the latest uploaded active DOCX.

If a generated draft exists but is not approved, and user asks for new changes, ask:

> У нас есть активная версия и есть черновик новой редакции, который еще не утвержден. В какую версию внести изменения: в активную или в черновик?

Do not silently choose.

### 5.5 After approval

When approved:

- mark old active version as archived/inactive;
- mark generated version as active;
- store source document / generated attachment relation;
- show the active version in “Муниципальная программа” section;
- future analysis must use this approved version;
- create an audit event.

---

## 6. Manual instruction workflow

Add a full workflow for manual instructions:

```text
User chat message
→ Agent detects manual_instruction source mode
→ ManualInstructionExtractor extracts structured patch
→ MissingFieldChecker checks required data
→ If incomplete: agent asks clarification
→ CandidateObjectFinder finds matching program objects using tree path + names
→ SemanticMatchAgent may resolve ambiguity
→ Deterministic calculator applies operation to target model
→ Parent chain is recalculated
→ Full program is validated
→ DOCX draft is generated
→ Report is generated
→ Chat shows download + approve buttons
```

### 6.1 ManualInstructionExtractor

Implement service/class:

```ruby
ManualInstructionExtractor
```

It may call OpenRouter LLM, but must return strict JSON and validate schema.

It should extract:

- operation type;
- object name;
- subprogram ref;
- main activity ref;
- activity ref;
- budget source;
- year/from_year/to_year;
- amount;
- units: rubles/thousand rubles/million rubles;
- whether amount is absolute or delta;
- original user text.

### 6.2 Units handling

Manual input can say:

- “1 млн” → 1,000,000 rub.;
- “1 000 тыс. руб.” → 1,000,000 rub.;
- “500 000 рублей” → 500,000 rub.;
- “90 млн” → 90,000,000 rub.

All internal storage remains rubles.

### 6.3 Candidate matching

Use all available clues:

- object name;
- object code if present;
- subprogram number/name;
- main activity number/name;
- activity number/name;
- parent path;
- funding source;
- years.

If exact path is provided and one object matches, confidence may be high.

If no exact object is found:

- if user says to add a new object and provides parent activity, create a new-object operation;
- otherwise ask clarification.

### 6.4 Targeted object recalculation

Add chat commands:

- “пересчитай объект …”;
- “проверь объект …”;
- “внеси правку по объекту …”;
- “сформируй новую редакцию только с этой правкой”;
- “почему изменилась сумма по нему?”;
- “покажи цепочку пересчета по этому объекту”.

The agent must locate the object, recalculate the object and all parents, then validate the program-level totals.

---

## 7. Agent memory and context compression

The agent currently sometimes forgets or replies as if it starts over. Improve memory.

Add/verify:

```text
conversation_summary
working_state
last_object_query
last_program_node_id
last_source_mode
last_generated_version_id
last_validated_draft_id
unresolved_clarification_question
```

### 7.1 Memory compaction

After N messages or M tokens, summarize older dialogue into `conversation_summary`.

Summary should preserve:

- active program;
- current draft;
- approved versions;
- source mode;
- last discussed object;
- requested operation;
- unresolved clarifications;
- user corrections/instructions.

### 7.2 Clear chat

“Очистить чат” must clear:

- visible messages;
- conversation summary;
- working_state related to conversation.

It must not delete:

- uploaded documents;
- active program versions;
- approved generated versions;
- procedure knowledge base;
- OpenRouter settings;
- agent settings.

---

## 8. UI requirements

### 8.1 Documents page

Keep separate areas:

1. Procedure/regulation PDF — normative knowledge base.
2. Current municipal program DOCX — baseline/active program upload.
3. Change-basis documents — Excel and PDF for changes.
4. Generated documents — generated DOCX/report versions.

Procedure PDF must be visually labeled:

> Нормативная база. Не используется как источник сумм.

Change-basis area must be visually labeled:

> Документы-основания для пересчета: Excel финансистов или PDF-основание.

### 8.2 Source mode selector

On workspace and/or documents page, expose:

- Автоматический выбор;
- Excel как целевая модель;
- PDF как основание изменений;
- Ручной ввод в чате;
- Excel + PDF как подтверждение.

Default: Автоматический выбор.

### 8.3 Active/draft versions

On “Муниципальная программа” page show:

- active version;
- uploaded versions;
- generated drafts;
- approved generated versions;
- buttons:
  - download;
  - make active/approve;
  - archive/delete where safe.

### 8.4 Clear/reset buttons

Add/verify clear buttons:

- Clear change-basis documents;
- Clear generated drafts;
- Clear change projects;
- Clear inactive versions;
- Clear all workspace data.

Each destructive action must have confirmation and must be scoped to the current organization only.

---

## 9. Audit and statistics

Add comprehensive audit logging for all agent actions.

Create/verify `AgentEvent` or equivalent:

Fields:

- organization_id;
- user_id;
- event_type;
- source_mode;
- related_document_ids;
- related_program_version_id;
- related_generated_version_id;
- related_change_project_id;
- input_summary;
- output_summary;
- validation_status;
- duration_ms;
- model_used;
- created_at.

Log at least:

- document upload;
- parsing start/end;
- source mode selection;
- manual instruction extraction;
- clarification question;
- object match decision;
- semantic match decision;
- recalculation start/end;
- DOCX generation start/end;
- validation result;
- draft approval;
- draft rejection;
- download link generation;
- cleanup action.

---

## 10. Required live E2E test protocol

This is mandatory. After implementation, Codex must run **live application tests** through the actual running app/browser/HTTP flow, not only unit tests.

Use the existing real uploaded/fixture documents as the basis. Generate new test Excel and PDF documents from the same structure; do not invent unrelated formats.

Create a final root report file:

```text
E2E_AGENT_VALIDATION_REPORT.md
```

The report must record every step, input, expected result, actual result, document IDs, generated version IDs, validation statuses, and pass/fail.

### 10.1 Excel scenario tests — 3 variants

Use the existing Excel finance report structure. Create 3 modified Excel files based on it.

Test A:

- modify 2–3 amounts for existing objects;
- run agent through chat: “проанализируй Excel и сформируй новую редакцию”;
- verify DOCX passport totals match modified Excel;
- verify source totals match modified Excel;
- verify “Всего” column is correct;
- approve generated DOCX;
- verify it becomes active.

Test B:

- start from approved version from Test A;
- create another Excel with new changes;
- run agent again;
- verify changes are applied to the approved active version, not the original uploaded version;
- approve generated DOCX.

Test C:

- create Excel with a zeroing/removal scenario and at least one new object if structurally possible;
- run agent;
- verify zeroing/removal and new object behavior;
- verify invalid residual rows are not inserted as fake objects.

### 10.2 PDF scenario tests — 3 variants

Create 3 PDF files based on real municipal agreement/change-document style and existing objects.

Test D:

- absolute amount change for an existing object;
- run agent using PDF source mode;
- verify only the specified patch is applied;
- verify PDF ledger validation passes.

Test E:

- transfer amount from one year to another for the same object/source;
- verify it becomes two operations: decrease old year, increase new year;
- verify parent chain and passport totals update.

Test F:

- ambiguous PDF object name;
- agent should ask a clarification question instead of guessing;
- after clarification, agent should complete generation.

### 10.3 Manual instruction tests — 3 variants

Run these through chat in the live UI/app.

Test G — complete manual request:

- provide full object, activity, main activity, subprogram, budget source, year, amount, operation;
- agent should not ask unnecessary questions;
- it should create a structured manual instruction, recalculate, generate DOCX, validate, and provide download/approve.

Test H — missing information:

- omit budget source or operation type;
- agent must ask a targeted clarification;
- after answer, agent must continue from context and generate DOCX.

Test I — version ambiguity:

- create a valid generated draft but do not approve it;
- ask for another manual change;
- agent must ask whether to apply to active version or draft;
- after user selects, apply correctly.

### 10.4 Full application tests

Also test:

- login;
- document upload;
- document delete buttons;
- clear chat;
- clear change-basis documents;
- clear generated drafts;
- clear inactive versions;
- source mode selector;
- OpenRouter model selection still works;
- no system/debug messages leak into chat;
- generated download links work;
- invalid DOCX is not shown as final;
- procedure PDF search still works as knowledge base;
- user asks procedural question and agent answers from procedure PDF, not from Excel/PDF change sources.

### 10.5 Required test commands

Run existing automated tests too:

```bash
docker-compose exec -T web bin/rails test
.venv/bin/python -m pytest parser_worker/tests
```

If commands differ in the current environment, document the exact commands used.

### 10.6 Completion rule

The task is complete only when:

- automated Rails tests pass;
- parser tests pass;
- all live E2E scenarios A–I pass;
- cleanup/UI tests pass;
- `E2E_AGENT_VALIDATION_REPORT.md` is created in project root;
- `WORKLOG.md`, `README.md`, and `агент.md` are updated;
- no new generated DOCX is marked final unless validation passed.

---

## 11. Reports

Generated reports must include:

- source mode;
- active baseline version used;
- generated draft version;
- whether draft was approved;
- list of changes;
- for manual changes: original user instruction and structured extracted patch;
- object path: subprogram → main activity → activity → object;
- year/source/old amount/new amount/delta;
- calculation summary;
- validation summary;
- unresolved issues, if any.

Do not show raw internal JSON to normal users, but keep it available in admin/audit views.

---

## 12. Acceptance criteria

1. The agent can use manual text instruction as a real change basis.
2. The agent asks clarifying questions when manual instruction is incomplete.
3. The agent can apply changes to a specific object using object + activity + main activity + subprogram context.
4. The agent can transfer funding between years as two operations.
5. The agent can generate a validated DOCX from manual input.
6. The generated DOCX can be downloaded and approved as the active version.
7. Future changes use the latest approved version.
8. If there is an unapproved draft, the agent asks which version to use.
9. Excel and PDF behavior remains correct.
10. Procedure PDF remains only a knowledge base.
11. The app has clear version cleanup controls.
12. All live E2E tests A–I pass and are documented.
13. The main agent communicates naturally in Russian and does not expose internal technical terms to the end user.

---

## 13. Suggested implementation order

1. Update agent instruction.
2. Add source mode `manual_instruction` and source mode selector behavior.
3. Add manual instruction extraction schema and service.
4. Add clarifying-question workflow and conversation memory fields.
5. Add targeted object matching/recalculation.
6. Add generated draft approval lifecycle.
7. Add UI buttons for download/approve/reject and version cleanup.
8. Add audit events.
9. Add automated tests.
10. Run live E2E tests A–I.
11. Write `E2E_AGENT_VALIDATION_REPORT.md`.
12. Update documentation.
