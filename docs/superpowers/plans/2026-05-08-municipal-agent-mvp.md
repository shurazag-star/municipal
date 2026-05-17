# Municipal Program Agent MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first executable MVP foundation for the municipal program agent: deterministic parsing, money math, duplicate handling, reconciliation, ChangeSet application, and Rails/Docker project scaffolding.

**Architecture:** Rails remains the target application shell from the specification, with a Python `parser_worker` owning deterministic document and finance logic. The first increment verified parser behavior under pytest; the current environment now runs the Rails/PostgreSQL/Redis/Sidekiq/parser_worker stack through Colima and `docker-compose`.

**Tech Stack:** Ruby on Rails target shell, PostgreSQL, Redis/Sidekiq target services, Python worker, openpyxl, python-docx, pypdf, pytest, Decimal money math, OpenRouter chat completions gateway.

---

### Task 1: Project Baseline

**Files:**
- Create: `TZ_AI_agent_municipal_programs.md`
- Create: `WORKLOG.md`
- Create: `README.md`
- Create: `storage/uploads/.gitkeep`
- Create: `storage/outputs/.gitkeep`
- Create: `storage/tmp/.gitkeep`

- [x] Save the technical specification in the project root.
- [x] Create storage directories required by section 18.3.
- [x] Record environment limits: no local Rails, no Docker daemon, no Docker Compose, inaccessible Downloads files.

### Task 2: Parser Worker TDD

**Files:**
- Create: `parser_worker/tests/test_money_and_sources.py`
- Create: `parser_worker/tests/test_row_classification.py`
- Create: `parser_worker/tests/test_excel_grouping.py`
- Create: `parser_worker/tests/test_tree_reconciliation_changeset.py`
- Create: `parser_worker/tests/test_docx_parser_fixture.py`
- Create: `parser_worker/tests/test_excel_parser_fixture.py`

- [x] Write failing tests for money parsing, source aliases, name normalization, row classification, duplicate grouping, residual handling, tree recalculation, DOCX fixture parsing, and XLSX fixture parsing.
- [x] Run `pytest` and confirm RED state caused by missing implementation.

### Task 3: Deterministic Core

**Files:**
- Create: `parser_worker/municipal_agent/money.py`
- Create: `parser_worker/municipal_agent/budget_sources.py`
- Create: `parser_worker/municipal_agent/normalization.py`
- Create: `parser_worker/municipal_agent/row_classification.py`
- Create: `parser_worker/municipal_agent/excel_parser.py`
- Create: `parser_worker/municipal_agent/docx_parser.py`
- Create: `parser_worker/municipal_agent/program_tree.py`
- Create: `parser_worker/municipal_agent/reconcile.py`
- Create: `parser_worker/municipal_agent/changeset.py`
- Create: `parser_worker/municipal_agent/agent_tools.py`

- [x] Implement minimal code to satisfy tests using Decimal for all sums.
- [x] Keep LLM-facing tool methods structured JSON only and never arithmetic by model.

### Task 4: Rails/Docker Scaffolding

**Files:**
- Create: `docker-compose.yml`
- Create: `Dockerfile.rails`
- Create: `parser_worker/Dockerfile`
- Create: `.env.example`
- Create: `rails_app/config/routes.rb`
- Create: `rails_app/app/models/*.rb`
- Create: `rails_app/app/controllers/dashboard_controller.rb`

- [x] Add target service topology from the spec.
- [x] Add model/controller placeholders matching schema and routes.
- [x] Document that full Rails generation must run in a Rails-capable environment.

### Task 5: Verification

- [x] Run parser worker pytest.
- [x] Run repository file/diff inspection.
- [x] Ensure no dev servers or background processes remain.
- [x] Append WORKLOG entry with changed files, checks, limitations, and next steps.

### Task 6: Real Document Integration

**Files:**
- Create: `агент.md`
- Create: `parser_worker/tests/test_real_documents_integration.py`
- Modify: `parser_worker/municipal_agent/docx_parser.py`
- Modify: `parser_worker/municipal_agent/excel_parser.py`
- Create: `parser_worker/municipal_agent/procedure_pdf_parser.py`
- Modify: `parser_worker/municipal_agent/agent_tools.py`

- [x] Copy real DOCX/XLSX/PDF files into `sample_documents/`.
- [x] Write failing tests against the real documents from the specification.
- [x] Extend parser worker to pass real DOCX passport/subprogram extraction.
- [x] Extend parser worker to pass real XLSX multi-row header, duplicate, residual, and total extraction.
- [x] Add PDF procedure text/rule extraction with pypdf.
- [x] Re-run pytest and update WORKLOG.

### Task 7: Runtime and OpenRouter Readiness

**Files:**
- Create: `parser_worker/municipal_agent/llm_gateway.py`
- Modify: `parser_worker/tests/test_llm_gateway.py`
- Modify: `rails_app/bin/rails`
- Modify: `rails_app/Gemfile`
- Modify: `rails_app/config/routes.rb`
- Modify: `docker-compose.yml`

- [x] Install and start local Docker runtime through Colima.
- [x] Build and start Rails, Sidekiq, PostgreSQL, Redis, and parser_worker containers.
- [x] Fix Rails executable and Sidekiq dependency issue found during runtime boot.
- [x] Add OpenRouter client with env-only key handling and current OpenRouter headers.
- [x] Verify Rails dashboard on `http://localhost:3000`.
- [x] Keep the stack running for user-side smoke testing.

### Task 8: Next Application Integration

**Files:**
- Modify: `rails_app/app/jobs/parse_document_job.rb`
- Modify: `rails_app/app/controllers/uploads_controller.rb`
- Modify: `rails_app/app/views/dashboard/index.html.erb`
- Modify: `parser_worker/municipal_agent/agent_tools.py`

- [x] Connect Rails uploads to parser_worker parsing results.
- [x] Persist parsed DOCX/XLSX/PDF payloads into Rails tables.
- [x] Add UI actions for reconciliation.
- [ ] Add DOCX patch/export flow after explicit user confirmation.

### Task 9: Usable Rails Agent Workflow

**Files:**
- Create: `rails_app/app/services/parser_worker_client.rb`
- Create: `rails_app/app/services/reconciliation_builder.rb`
- Create: `rails_app/app/services/agent_report_builder.rb`
- Create: `rails_app/app/controllers/agent_explanations_controller.rb`
- Create: `rails_app/app/views/layouts/application.html.erb`
- Create: `rails_app/app/views/dashboard/_upload_card.html.erb`
- Create: `rails_app/app/helpers/dashboard_helper.rb`
- Create: `rails_app/test/**`
- Modify: `rails_app/app/controllers/application_controller.rb`
- Modify: `rails_app/app/controllers/sessions_controller.rb`
- Modify: `rails_app/app/controllers/uploads_controller.rb`
- Modify: `rails_app/app/controllers/dashboard_controller.rb`
- Modify: `rails_app/app/jobs/parse_document_job.rb`
- Modify: `rails_app/app/models/audit_log.rb`
- Modify: `rails_app/app/models/program_version.rb`
- Modify: `Dockerfile.rails`
- Modify: `docker-compose.yml`

- [x] Require login and expose a clear login screen.
- [x] Fix `AuditLog.record!` polymorphic target persistence.
- [x] Split upload UI into DOCX, XLSX, and PDF cards.
- [x] Connect upload flow to `ParseDocumentJob`.
- [x] Invoke parser_worker CLI from Rails/Sidekiq containers.
- [x] Persist `parsed_payload` on `SourceDocument`.
- [x] Build reconciliation rows from parsed DOCX/XLSX totals.
- [x] Show parsed document status and control-sum diffs in dashboard.
- [x] Add OpenRouter explanation action that becomes usable after `OPENROUTER_API_KEY` is set.
- [x] Verify the browser flow on real uploaded DOCX/XLSX/PDF files.

### Task 10: Confirmed ChangeSet and DOCX Export

**Files:**
- Modify: `rails_app/app/controllers/change_sets_controller.rb`
- Modify: `rails_app/app/views/change_sets/show.html.erb`
- Modify: `rails_app/app/controllers/documents_controller.rb`
- Modify: `parser_worker/municipal_agent/changeset.py`

- [ ] Build review UI for proposed amount/name/result changes.
- [ ] Require explicit user confirmation before applying a ChangeSet.
- [ ] Generate updated DOCX only from an approved ChangeSet.
- [ ] Add browser tests for confirmation and export.
