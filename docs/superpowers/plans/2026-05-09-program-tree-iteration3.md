# Program Tree Iteration 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Расширить DOCX parsing до дерева программы и сохранить это дерево в Rails `ProgramNode`/`FundingLine`.

**Architecture:** Python parser worker возвращает backward-compatible payload плюс новые массивы `nodes` и `funding_lines` с координатами DOCX. Rails `ProgramTreePersister` создает/обновляет активную `MunicipalProgram`/`ProgramVersion`, атомарно заменяет дерево версии и сохраняет строки финансирования с ссылкой на исходный `SourceDocument`.

**Tech Stack:** Rails 8 Active Record, PostgreSQL jsonb/decimal, Minitest, Python `python-docx`, pytest, Docker Compose.

---

### Task 1: Parser RED Tests

**Files:**
- Modify: `parser_worker/tests/test_docx_parser_fixture.py`
- Modify: `parser_worker/tests/test_real_documents_integration.py`
- Modify: `parser_worker/tests/test_cli_real_documents.py`

- [x] **Step 1: Write failing tests**
  Add tests for `ParsedDocxProgram.nodes`, `ParsedDocxProgram.funding_lines`, node coordinates, funding cell coordinates and real `Черусти` extraction.

- [x] **Step 2: Run parser tests to verify failure**
  Run: `./.venv/bin/python -m pytest parser_worker/tests/test_docx_parser_fixture.py parser_worker/tests/test_real_documents_integration.py parser_worker/tests/test_cli_real_documents.py -q`
  Expected: FAIL with missing `nodes`/`funding_lines`.

### Task 2: Rails Persister RED Tests

**Files:**
- Create: `rails_app/test/services/program_tree_persister_test.rb`
- Modify: `rails_app/test/jobs/parse_document_job_test.rb`

- [x] **Step 1: Write failing tests**
  Cover creating nodes/lines from parsed payload and `ParseDocumentJob` calling the persister for `docx_program`.

- [x] **Step 2: Run Rails target tests to verify failure**
  Run: `docker-compose exec -T -e RAILS_ENV=test -e DATABASE_URL=postgres://postgres:postgres@postgres:5432/municipal_agent_test web bundle exec rails test test/services/program_tree_persister_test.rb test/jobs/parse_document_job_test.rb`
  Expected: FAIL with missing `ProgramTreePersister`.

### Task 3: Implement DOCX Parser Tree Output

**Files:**
- Modify: `parser_worker/municipal_agent/docx_parser.py`

- [x] **Step 1: Add parser dataclasses**
  Add `ParsedProgramNode` and `ParsedFundingLine`, preserving existing `subprograms`, `passport_amounts`, and `passport_totals_by_year`.

- [x] **Step 2: Extract program root and subprogram nodes**
  Parse program name/period from paragraphs and build stable keys.

- [x] **Step 3: Extract result nodes**
  Parse table rows with `Наименование результата`.

- [x] **Step 4: Extract financial tree rows**
  Parse finance tables with columns `№ п/п`, `Мероприятие`, `Источники финансирования`, years. Classify main activities, activities, objects, and create funding lines only for recognized budget sources, not `Итого`.

- [x] **Step 5: Run parser target tests**
  Run parser target tests until GREEN.

### Task 4: Implement Rails ProgramTreePersister

**Files:**
- Create: `rails_app/app/services/program_tree_persister.rb`
- Modify: `rails_app/app/jobs/parse_document_job.rb`
- Modify: `rails_app/app/services/agent_context_builder.rb`
- Modify: `rails_app/app/views/program_versions/show.html.erb`

- [x] **Step 1: Create/update program/version**
  Use parsed `program` payload when present, fallback to `Название не определено`.

- [x] **Step 2: Replace version tree atomically**
  In a transaction, delete old nodes and create new `ProgramNode` records keyed by parser `stable_key`.

- [x] **Step 3: Persist funding lines**
  Map parser `source_type` values to Rails enum keys and save source coordinates in `metadata`.

- [x] **Step 4: Connect job and context**
  Call persister after `docx_program` parse; use persisted node count for context.

- [x] **Step 5: Run Rails target tests**
  Run Rails target tests until GREEN.

### Task 5: Verification and Dev Data

**Files:**
- Modify: `WORKLOG.md`

- [x] **Step 1: Full automated checks**
  Run full Rails tests, full parser tests, Ruby syntax, Python compileall, Docker Compose config.

- [x] **Step 2: Dev reparse**
  Reparse already uploaded dev DOCX if attached, then confirm `ProgramNode` and `FundingLine` counts.

- [x] **Step 3: Browser smoke**
  Open program version page and workspace, verify visible node/funding counts and no console errors.

- [x] **Step 4: Update WORKLOG**
  Append changed files, checks, result, risks, next stage.
