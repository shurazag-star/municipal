# CODEX TASK 07 — autonomous municipal program agent: memory, no manual row confirmations, clean document roles

## Implementation status

- [x] Saved this plan in the project root.
- [x] Replaced the default agent instruction with the autonomous English system prompt and added `rails agent_settings:reset_default_prompt`.
- [x] Added autonomous resolution fields for change rows and an `AgentAutonomousResolver`.
- [x] Removed manual row/project confirmation from the main user workflow and hidden confirmation controls from the normal UI.
- [x] Changed export validation so a project can be applied after autonomous resolution and self-checks, without user approval of every row.
- [x] Added conversation memory fields, `AgentMemoryService`, follow-up routing for “покажи список” and object-pronoun follow-ups.
- [x] Strictly separated procedure PDF as knowledge only from XLSX/PDF agreement change sources.
- [x] Added source-priority policy for Excel/PDF conflicts and applied it during autonomous resolution.
- [x] Added `AgentTask` and `AgentTaskJob` for long-running chat workflows.
- [x] Fixed DOCX program versioning by tying imported versions to `source_document_id` and switching active versions by document.
- [x] Added cleanup buttons/actions for change sources, projects, program versions and all workspace data.
- [x] Cleaned user UI wording away from confidence/manual-confirmation workflow.
- [x] Removed `pending_implementation` Python agent-tool stubs; Rails `AgentToolRegistry` is the runtime tool layer.
- [x] Updated tests for the autonomous workflow and verified the Rails test suite.
- [x] Verified the real-document scenario: project #195 applied, DOCX/report attached, 0 manual insert rows, post-export validation valid, self-check passed.

## Current review summary

The latest code is much better than the original debug dashboard, but it is **not yet the final client workflow**.

What is already good:

- `Dockerfile.rails` now installs LibreOffice, poppler, tesseract, `rus` and `eng`, so OCR can work in Rails/Sidekiq.
- The workspace has a chat, context panel, document slots, quick actions and settings.
- `AgentIntentRouter`, `AgentWorkflowRunner`, `AgentToolRegistry`, `AgentAnswerGenerator`, `AgentSelfCheckService` exist.
- DOCX, XLSX, procedure PDF and agreement PDF parsing exist.
- PDF agreement OCR fallback exists.
- Generated DOCX can be validated and rendered.
- User/system/tool roles are mostly separated in the visible chat.

The remaining product problems:

1. The agent still behaves too much like a command router. It does not reliably continue a natural dialogue.
2. The agent still asks the user to confirm rows/projects. The new product requirement is: **the user should not manually confirm individual rows or a project**. The agent must resolve changes autonomously using tools, calculations, semantic matching and self-checks.
3. The procedure PDF must be treated only as a knowledge base / rulebook. It must never be compared to Excel/PDF change sources and must never participate in money calculations.
4. The agent currently may answer a follow-up like “покажи список” with a generic project summary instead of the list it just offered to show. This is a memory/state problem.
5. Conversation memory is shallow: only the last messages are sent. There is no compacted working memory, no task state, no last referenced object, no learned correction memory.
6. Program versions and change projects are hard to clear/reset from the UI.
7. DOCX program import/versioning is suspicious: a new uploaded DOCX can reuse/overwrite the current version instead of creating a clean imported version tied to the source document.
8. The customer UI still exposes “Подтвердить проект”, “Подтвердить строку”, confidence, `needs_confirmation`-style logic. This no longer matches the required autonomous-agent workflow.
9. `parser_worker/municipal_agent/agent_tools.py` still contains many `pending_implementation` tool stubs. Either remove it from the agent-facing architecture or make it clearly non-runtime; otherwise it gives the false impression that the agent has tools that are not real.

Do not rewrite the project from scratch. Refactor the current implementation.

---

## Product target

The user workflow must be:

1. User uploads the local procedure/rules PDF into “Порядок разработки / постановление”.
2. User uploads the current municipal program DOCX into “Текущая редакция муниципальной программы”.
3. User uploads one or more change-source documents into “Документы-основания для изменений”: finance XLSX and/or ministry/agreement PDFs.
4. User talks to the agent in Russian, for example:
   - “проанализируй документы”
   - “где несовпадения?”
   - “покажи список”
   - “что поменялось по Черустям?”
   - “пересчитай программу”
   - “сформируй новую редакцию”
   - “проверь еще раз”
5. Agent autonomously uses tools, calculations, semantic matching, knowledge base and self-checks.
6. Agent does **not** ask the user to manually confirm rows.
7. Agent produces a validated DOCX and a report, then gives download cards directly in chat.
8. If the agent cannot safely resolve something after autonomous attempts, it must say exactly what cannot be resolved and why. It must not silently apply uncertain changes. It may ask one targeted clarification question only when the documents genuinely do not contain enough information.

The user should experience the system as: “I gave documents and instructions; the agent did the work and gave me the result.”

---

## 1. Replace the default agent instruction with this English prompt

Update `AgentSetting::DEFAULT_SYSTEM_PROMPT` with the following English instruction. Keep the UI label in Russian. The instruction is intentionally English, but it explicitly requires Russian user communication.

```text
You are an autonomous AI agent for municipal program amendments. You work inside a Rails web application. Your user communicates in Russian, and every user-facing answer must be in Russian unless the user explicitly asks otherwise.

Your mission is to help the user produce a correct new DOCX version of a municipal program based on uploaded documents. You must preserve the original DOCX formatting as much as the available DOCX patching tools allow, recalculate the budget hierarchy, validate control sums, prepare an amendment report, and explain your decisions clearly.

Document roles are strict:
1. Procedure / ordinance PDF: this is the knowledge base and rulebook only. Use it to answer questions about structure, procedure, deadlines, approvals, required sections, and legal/process rules. Never use it as a financial change source. Never compare it against Excel or agreement PDFs as if it contained program funding changes.
2. Current municipal program DOCX: this is the editable baseline document. Parse it into the program tree: program -> subprogram -> main activity -> activity -> object -> funding lines by year and funding source.
3. Change-source documents: finance XLSX reports and ministry/agreement PDFs. These documents contain the funding/object changes that must be applied to the DOCX baseline.

You are the main operator of the workflow. Do not behave like a passive chatbot. For every user request, inspect the workspace state, decide what is missing, plan the next tool steps, run the necessary tools, verify the results, and explain the outcome. Use conversation memory to understand follow-ups such as “show the list”, “why this one?”, “check it again”, or “what about this object?”.

You may use tools for: reading parsed documents, searching the procedure knowledge base, matching external rows to program objects, recalculating funding trees, checking vertical and horizontal sums, detecting duplicates, detecting conflicts between change sources, applying source-priority rules, preparing amendment projects, patching DOCX, rendering DOCX, validating the exported document, and generating reports.

Financial accuracy rules:
- You must not invent numbers.
- All monetary arithmetic must be performed or verified through calculation tools that use exact decimal arithmetic.
- You may reason about calculations, request recalculation, compare tool outputs, and explain the math, but final amounts must come from tools or uploaded documents.
- Store money internally in rubles with decimal precision. Respect source document units when displaying values.
- Always verify that object sums roll up to activities, activities to main activities, main activities to subprograms, and subprograms to the program passport totals.

Autonomous resolution rules:
- The user should not manually confirm individual change rows.
- Resolve rows yourself using deterministic matching first: codes, normalized names, parent activity codes, year/source/amount consistency, hierarchy location, and duplicate grouping.
- When deterministic matching is not enough, use the LLM only for semantic matching and explanation, with a strict JSON result. The LLM may choose between candidate objects, mark a row as a new object, detect that a row is an aggregate/residual, or mark the row unresolved with reasons. The LLM must not create unsupported amounts.
- Run at least one self-check after autonomous resolution. If a proposed match breaks control sums or hierarchy totals, reject or retry it.
- Do not show internal confidence percentages to the user as a required action. Use them internally only.
- If a row remains genuinely unresolved after retries, do not apply it silently. Explain the exact blocker and what document/evidence is missing.

Source-priority rules:
- If a finance XLSX report is present, treat it as the consolidated financial source by default.
- PDF agreements are valid change sources when XLSX is absent, or as supporting evidence when they agree with XLSX.
- If XLSX and PDF disagree on the same object/year/source, use the configured organization source-priority policy. If no policy is configured, default to XLSX as the final consolidated source and mention the PDF discrepancy in the report.
- The procedure PDF is never part of source conflicts.

Dialogue rules:
- Answer naturally and professionally in Russian.
- Do not greet the user again in every response. Greet only at the start of a new empty conversation or after the user greets you.
- Do not expose internal implementation terms such as ChangeSet, parser, worker, intent, tool, JSON, LlmRun, post_export_validation, manual_insert_required, INSERTED_IN_DOCX, PROGRAM_TOTAL_DIFF, deterministic, or class/service names.
- Instead of technical terms, say: “проект изменений”, “разбор документов”, “проверка документа”, “готовая новая редакция”, “строки, которые нужно разобрать”, “контрольные суммы”.
- If a user asks “show the list” after you offered a list, show that list. Use the previous assistant message and conversation state.
- If documents are missing, tell the user exactly which slot is missing and what to upload.
- If the final DOCX is valid, provide download links/cards in chat.
- If the final DOCX is not valid, do not call it ready. Explain the failed checks and next action.

Memory rules:
- Use compact conversation memory. Remember the current task, last referenced object, source priority decisions, unresolved issues, user corrections, and successful/failed workflow steps.
- Do not store raw long documents in chat memory. Documents live in the document store and knowledge base.
- When chat history grows, summarize it into compact working memory and continue from that summary.
- If the user clears the chat, clear conversation messages and conversational memory only. Do not delete uploaded documents, program versions, change projects, or generated files unless the user explicitly uses a separate reset/delete action.

Final output rules:
- A final DOCX can be offered only after: all applied rows are resolved, the funding tree is recalculated, passport totals match the target model, the DOCX is patched, the generated DOCX is parsed again, visual/render validation succeeds or has only allowed warnings, and the report is attached.
- Always provide a short summary of what changed: number of changed rows, years affected, sources used, unresolved/excluded items if any, and checks passed.
```

Acceptance:

- The default text in “Настройка агента” is the prompt above.
- Existing organizations that still have the old default Russian prompt should be migratable through a rake task or migration: `rails agent_settings:reset_default_prompt`.
- The agent must still answer in Russian.

---

## 2. Remove manual row/project confirmations from the main workflow

### Problem

Current code still has manual confirmation everywhere:

- `ChangeItem.requires_user_confirmation`
- `user_confirmed`
- statuses like `needs_confirmation`, `pending_confirmation`
- buttons: “Подтвердить строку”, “Подтвердить проект”
- agent tools: `confirm_change_items`, `approve_change_project`
- export is blocked until these manual confirmations happen.

This contradicts the updated requirement.

### Required behavior

The agent must autonomously resolve changes and then apply them after internal self-checks. The user should not have to confirm 56 rows manually.

### Implementation plan

1. Keep existing DB columns for backward compatibility, but stop using them as the primary blocker in the user workflow.
2. Introduce autonomous resolution states. Either add columns or use `source_reference`/`metadata`, but prefer explicit columns if time allows:
   - `agent_resolution_status`: `unresolved`, `resolved`, `excluded`, `needs_clarification`
   - `agent_resolution_reason`
   - `agent_resolution_evidence` JSONB
   - `agent_resolver_model`
   - `agent_resolved_at`
3. Create service:
   - `AutonomousChangeResolutionService`
   - or `AgentAutonomousResolver`

It must process every change item before application.

Resolution passes:

- pass 1: exact code match;
- pass 2: normalized exact name match;
- pass 3: parent activity code + object name fuzzy match;
- pass 4: amount/year/source consistency match;
- pass 5: LLM semantic candidate selection with strict JSON schema;
- pass 6: recalculate tree and validate that the selected mapping does not break totals;
- pass 7: mark as resolved/excluded/needs_clarification.

4. Change `ChangeSetBuilder` behavior:
   - new object rows are not automatically “needs user confirmation”; they become `unresolved` until the autonomous resolver either inserts them, maps them, or excludes them with evidence.
   - OCR rows are not automatically user-confirmation rows; they are “needs stronger autonomous verification”.
   - transfer/zeroing/conflict rows are not user-confirmation rows; they go through autonomous resolution.
5. Change `ChangeSetApplicationService#validate_change_set!`:
   - do not require `approved?` from the user;
   - require all change items to be `agent_resolution_status IN ('resolved', 'excluded')`;
   - require no unresolved source conflicts according to source-priority policy;
   - require self-check preflight.
6. Add `AgentAutoApplyService` that runs:
   - analysis;
   - autonomous resolution;
   - preflight checks;
   - application;
   - DOCX patch;
   - post-export validation;
   - report;
   - final chat message with links.
7. Remove or hide from normal user UI:
   - “Подтвердить строку”;
   - “Подтвердить проект”;
   - confirmation column;
   - raw confidence column.
8. Keep an admin/audit page if needed, but label it as internal diagnostics.

### Acceptance

When the user writes “сформируй новую редакцию” after uploading the three required document groups, the agent must not ask for row confirmations. It must autonomously resolve, apply, validate and either:

- give DOCX/report links, or
- say exactly which rows cannot be resolved and why, without applying them silently.

---

## 3. Make the agent truly conversational and stateful

### Observed bug

The agent says something like “Показать список неподтвержденных строк?”, then the user writes “покажи список”, and the agent returns only a generic summary of the latest project.

### Required fix

Add conversation state and follow-up handling.

Implement:

1. Add columns to `agent_conversations`:
   - `memory_summary` text
   - `working_state` jsonb default `{}`
   - `memory_updated_at` datetime
2. Add `AgentMemoryService`:
   - updates memory after every assistant response;
   - stores compact summary of current task, last referenced object, last offered action, source priority, unresolved issues, generated files, and user corrections;
   - never stores raw long document text;
   - keeps memory under a configurable char budget, e.g. 3500–5000 chars.
3. Add `AgentConversationCompactor`:
   - if visible chat exceeds N messages or estimated token budget, summarize older turns into `memory_summary`;
   - keep only recent visible messages plus summary for LLM answer generation;
   - do not delete audit logs unless explicitly clearing chat.
4. Update `AgentAnswerGenerator#user_prompt` and `AgentIntentRouter#llm_user_prompt` to include:
   - `conversation.memory_summary`;
   - `conversation.working_state`;
   - last assistant question/action.
5. Add follow-up routing:
   - if last assistant offered pending/unresolved list and user says “покажи”, “да”, “список”, route to `show_unresolved_items`;
   - if last assistant discussed a specific object and user says “по нему”, “почему”, “проверь”, use `last_referenced_object`;
   - if last assistant said a file is ready and user says “дай файл”, route to `list_generated_documents`.
6. Change smalltalk:
   - do not always answer with “Здравствуйте”.
   - If conversation already has context, answer briefly: “На связи. Могу продолжить анализ, показать расхождения или сформировать новую редакцию.”

### Acceptance tests

Add integration tests:

- user: “покажи список” immediately after agent offered a list -> agent shows actual items;
- user: “что по Черустям?” then “почему по нему изменилась сумма?” -> agent uses Черусти;
- user clears chat -> messages and memory clear, documents remain;
- no repeated greeting in the middle of a working conversation.

---

## 4. Strictly separate knowledge base from change sources

### Problem

The procedure PDF is a rulebook. It must not be treated as a financial source. The agent must never say there is a funding conflict between the procedure PDF and Excel.

### Required changes

1. `AnalysisSessionRunner::CHANGE_SOURCE_TYPES` must be only:
   - `xlsx_finance`
   - `pdf_agreement`

Remove `other` from change-source analysis unless there is a specific parser and product reason.

2. `AgentToolRegistry#parsed_change_sources` must return:
   - latest parsed XLSX finance report;
   - all parsed PDF agreements;
   - no `pdf_procedure`;
   - no `other` by default.

3. `SourceConflictDetector` must only compare actual change sources. Add explicit guard:
   - ignore anything that is not `xlsx_finance` or `pdf_agreement`.

4. `KnowledgeRetriever` must only search chunks generated from `pdf_procedure` documents.

5. UI labels:
   - Procedure slot: “Порядок разработки / нормативная база — не источник сумм”.
   - Change source slot: “Документы-основания для изменений — Excel финансистов или PDF-соглашения”.

6. Agent prompt and response composer:
   - if user asks a process/legal question, use procedure knowledge base;
   - if user asks to recalculate/apply changes, use only DOCX + change-source documents.

### Acceptance

Upload procedure PDF + DOCX + XLSX. Agent must not mention conflict between procedure PDF and XLSX. Procedure PDF can be cited only for process/rules.

---

## 5. Add autonomous conflict policy between Excel and PDF

### Required default policy

For this product, the default should be:

- If XLSX finance report is present, it is the consolidated final financial model.
- PDF agreements are used as evidence/supporting sources and as primary change sources only when no XLSX exists for the affected object/year/source.
- If XLSX and PDF disagree, default to XLSX unless organization settings specify otherwise.
- The conflict must be recorded in the report, but it must not block the workflow by asking the user to choose every time.

Add setting:

- `organization.settings['source_priority_policy']`
  - `xlsx_over_pdf` default
  - `pdf_over_xlsx`
  - `latest_uploaded`
  - `ask_user` optional, not default

Update `choose_source_priority` to set this policy globally, not only as a one-off text marker.

### Acceptance

If Excel and PDF disagree, the agent applies the configured policy, explains it in Russian, records the conflict in the report, and continues if checks pass.

---

## 6. Long-running agent tasks instead of blocking chat requests

The agent may need many minutes for a real municipal program. Do not run the entire workflow synchronously inside `AgentMessagesController#create`.

Implement:

1. `AgentTask` model:
   - organization_id
   - user_id
   - agent_conversation_id
   - status: queued/running/succeeded/failed/cancelled
   - task_type: analysis/autonomous_resolution/export/full_workflow
   - input_message
   - progress_payload JSONB
   - result_payload JSONB
   - error_message
2. `AgentTaskJob` / `AgentWorkflowJob` in Sidekiq.
3. Chat UX:
   - after user request, immediately create user message and assistant placeholder: “Принял задачу, выполняю анализ.”
   - show progress humanly: “Разбираю Excel”, “Сопоставляю объекты”, “Пересчитываю суммы”, “Проверяю DOCX”.
   - when job completes, replace/update assistant message or append final assistant message with result and download cards.
4. Allow long timeouts in job execution; do not rely on a single LLM call. Use bounded LLM calls per subtask.

Acceptance:

A full “проанализируй и сформируй DOCX” task can run in Sidekiq without freezing the browser or losing chat state.

---

## 7. Fix municipal program versioning and add cleanup buttons

### Program versioning issue

`ProgramTreePersister#ensure_version!` currently reuses `program.current_version` or the first version. For uploaded source DOCX files this can overwrite the active version’s tree instead of creating a new imported version tied to the uploaded file.

Required:

1. Every parsed `docx_program` upload creates a new `ProgramVersion` with:
   - incremented `version_number`;
   - `status: imported`;
   - `import_summary['source_document_id'] = source_document.id`.
2. `make_active` must find the version where `import_summary.source_document_id == document.id` and set it as current.
3. Generated DOCX versions remain separate `changed` versions tied to source change project.
4. Do not silently overwrite current version trees.

### Cleanup buttons

Add organization-scoped reset actions with strong confirmation modals:

- “Очистить документы-основания” — delete XLSX/PDF agreement/other change-source docs and dependent analyses/projects.
- “Очистить проекты изменений” — delete analysis sessions, change projects, generated docs/reports; keep documents and active program.
- “Очистить версии программы” — delete municipal programs/versions/nodes/funding lines/change projects; keep uploaded source docs unless user chooses all.
- “Очистить все рабочие данные” — delete procedure docs, program docs, change docs, analyses, projects, generated files, programs/versions; keep organization, users, OpenRouter settings and agent settings.

Routes should be organization-scoped and protected. Add audit logs.

Acceptance:

The user can clean the demo workspace without manual database commands.

---

## 8. Make the user UI non-technical

Remove from normal user-facing pages or move to admin/debug:

- confidence percentages;
- “Подтвердить строку”;
- “Подтвердить проект”;
- raw statuses: `pending_confirmation`, `needs_confirmation`, `applied`, `export_failed`;
- technical service names;
- raw source enums.

Replace with human labels:

- “Агент сопоставил”
- “Агент исключил из применения”
- “Нужно уточнение: недостаточно данных в документах”
- “Готово к формированию”
- “Документ сформирован и проверен”
- “Документ не готов: проверка не пройдена”

The “Проекты изменений” page may remain, but it should be an audit/explanation page, not a manual confirmation interface.

---

## 9. Make agent tools real and consistent

`parser_worker/municipal_agent/agent_tools.py` still contains stubs such as `pending_implementation`. Decide one of two paths:

Option A — Rails is the real tool layer:
- remove these stubs from any agent-facing docs;
- document that `AgentToolRegistry` is the real runtime tool registry;
- keep parser_worker only for parsing and DOCX patching.

Option B — implement wrappers:
- make each tool call the real Rails service or parser function;
- remove `pending_implementation` responses.

For MVP, choose Option A unless there is a strong reason to expose Python tools.

Acceptance:

No part of the app tells the user or developer that the agent has a working tool when it is a stub.

---

## 10. Tests and acceptance scenarios

Add/modify tests:

1. Full UI/job scenario with real documents:
   - upload procedure PDF;
   - upload DOCX;
   - upload XLSX;
   - user writes “проанализируй и сформируй новую редакцию”;
   - no manual row/project confirmation occurs;
   - agent performs autonomous resolution;
   - final DOCX/report cards appear if checks pass.
2. Procedure PDF is knowledge only:
   - analysis sources exclude `pdf_procedure`;
   - no source conflict with procedure PDF.
3. Follow-up memory:
   - agent offers list;
   - user says “покажи список”;
   - list appears.
4. Object memory:
   - user asks about Черусти;
   - follow-up “почему по нему?” resolves to Черусти.
5. Versioning:
   - uploading two DOCX files creates two imported versions;
   - make_active switches to the selected source document’s version.
6. Cleanup:
   - clear change projects;
   - clear versions;
   - clear all workspace data;
   - all actions are organization-scoped.
7. No technical vocabulary in user chat:
   - assert visible assistant messages do not contain: `ChangeSet`, `parser`, `worker`, `intent`, `tool`, `JSON`, `manual_insert_required`, `PROGRAM_TOTAL_DIFF`.
8. Agent prompt:
   - default prompt includes “every user-facing answer must be in Russian”;
   - reset task updates old defaults.

Update:

- README.md
- WORKLOG.md
- агент.md
- screenshots/smoke notes if applicable

---

## Final acceptance definition

The feature is done only when this scenario works:

> A new user opens the app, uploads the procedure PDF, uploads current DOCX, uploads finance XLSX or PDF agreement documents, writes in chat “проанализируй и сформируй новую редакцию”, waits for the agent task, and receives a checked DOCX plus report in chat. The user never confirms individual rows. The procedure PDF is used only as knowledge. The agent can answer follow-up questions naturally and remembers the current object/task until the chat is cleared.
