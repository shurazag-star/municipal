# Knowledge Base Iteration 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Завершить итерацию 2: отдельные документы уже есть, теперь PDF-порядок должен индексироваться в постоянную базу знаний, показываться в UI и попадать в контекст агента.

**Architecture:** Rails хранит `KnowledgeChunk` на организацию и документ, `ParseDocumentJob` вызывает `KnowledgeIndexer` после разбора PDF-порядка, `/knowledge_base` ищет через `KnowledgeRetriever`. Python parser worker возвращает страницы и типизированные chunks, а UI рабочего места фиксирует высоту чата и переносит длинные документы внутри context panel.

**Tech Stack:** Rails 8, Active Record/PostgreSQL jsonb, Minitest, Python `pypdf`, pytest, Docker Compose, Browser plugin.

---

### Task 1: Workspace Layout Guardrails

**Files:**
- Modify: `rails_app/test/integration/agent_workspace_test.rb`
- Modify: `rails_app/app/views/layouts/application.html.erb`

- [x] **Step 1: Write the failing test**
  Add an integration assertion that the layout stylesheet contains the scroll and wrapping rules needed for the chat and context panel.

- [x] **Step 2: Run test to verify it fails**
  Run: `docker-compose exec -T -e RAILS_ENV=test -e DATABASE_URL=postgres://postgres:postgres@postgres:5432/municipal_agent_test web bundle exec rails test test/integration/agent_workspace_test.rb`
  Expected: FAIL until CSS contains `overflow-wrap: anywhere` and viewport-limited chat/context rules.

- [x] **Step 3: Write minimal implementation**
  Update inline CSS in `application.html.erb` only; do not change routes or business behavior.

- [x] **Step 4: Run test to verify it passes**
  Run the same Rails integration test.

### Task 2: KnowledgeChunk Storage and Indexing

**Files:**
- Create: `rails_app/db/migrate/20260509001000_create_knowledge_chunks.rb`
- Create: `rails_app/app/models/knowledge_chunk.rb`
- Create: `rails_app/app/services/knowledge_indexer.rb`
- Modify: `rails_app/app/models/organization.rb`
- Modify: `rails_app/app/models/source_document.rb`
- Modify: `rails_app/app/jobs/parse_document_job.rb`
- Test: `rails_app/test/services/knowledge_indexer_test.rb`
- Test: `rails_app/test/jobs/parse_document_job_test.rb`

- [x] **Step 1: Write failing tests**
  Cover indexing parsed `chunks`, fallback indexing from legacy `rules`, and `ParseDocumentJob` creating chunks for `pdf_procedure`.

- [x] **Step 2: Run tests to verify they fail**
  Run: `docker-compose exec -T -e RAILS_ENV=test -e DATABASE_URL=postgres://postgres:postgres@postgres:5432/municipal_agent_test web bundle exec rails test test/services/knowledge_indexer_test.rb test/jobs/parse_document_job_test.rb`
  Expected: FAIL with missing `KnowledgeChunk`/`KnowledgeIndexer`.

- [x] **Step 3: Implement storage/indexing**
  Add the migration, associations, model validation, and `KnowledgeIndexer#index!`.

- [x] **Step 4: Run migration and tests**
  Run `rails db:migrate`, `rails db:prepare` for test, then the target tests.

### Task 3: Knowledge Base Search UI

**Files:**
- Create: `rails_app/app/services/knowledge_retriever.rb`
- Modify: `rails_app/app/controllers/knowledge_chunks_controller.rb`
- Modify: `rails_app/app/views/knowledge_chunks/index.html.erb`
- Test: `rails_app/test/integration/knowledge_base_test.rb`

- [x] **Step 1: Write failing integration test**
  Verify `/knowledge_base` lists indexed chunks, searches by text, and does not leak chunks from another organization.

- [x] **Step 2: Run test to verify it fails**
  Run: `docker-compose exec -T -e RAILS_ENV=test -e DATABASE_URL=postgres://postgres:postgres@postgres:5432/municipal_agent_test web bundle exec rails test test/integration/knowledge_base_test.rb`

- [x] **Step 3: Implement retriever and UI**
  Use sanitized `ILIKE` over title/content/chunk_type, group results by section, and show active procedure metadata.

- [x] **Step 4: Run target test**
  Run the same integration test.

### Task 4: PDF Procedure Chunks

**Files:**
- Modify: `parser_worker/municipal_agent/procedure_pdf_parser.py`
- Modify: `parser_worker/tests/test_real_documents_integration.py`

- [x] **Step 1: Write failing parser test**
  Assert parser output includes `pages` and required chunk types: `procedure_general`, `program_structure`, `indicators_and_results`, `change_procedure`, `approval_terms`, `forms`, `reporting`.

- [x] **Step 2: Run test to verify it fails**
  Run: `./.venv/bin/python -m pytest parser_worker/tests/test_real_documents_integration.py -q`

- [x] **Step 3: Implement parser chunks**
  Extract per-page normalized text and build deterministic best-effort chunks by keyword category.

- [x] **Step 4: Run parser tests**
  Run the target parser test and then full parser test suite.

### Task 5: Verification and Log

**Files:**
- Modify: `WORKLOG.md`

- [x] **Step 1: Run full checks**
  Rails target tests, full Rails tests, parser tests, Ruby syntax, Python compileall, Docker config.

- [x] **Step 2: Browser QA**
  Open `http://localhost:3000`, log in if needed, inspect desktop/mobile workspace screenshots, verify no horizontal overflow and chat internal scroll.

- [x] **Step 3: Update WORKLOG**
  Append date/time, changed files, commands, browser QA, result, risks, next iteration.
