# Chat Agent Workspace Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current technical dashboard into a working municipal-program chat-agent workspace for Iteration 1 of `CODEX_TASK_02_CHAT_AGENT_REFACTOR.md`.

**Architecture:** Rails owns the workspace, chat persistence, organization-scoped context, settings and deterministic quick actions. Parser worker and OpenRouter model registry remain intact; Iteration 1 does not patch DOCX and does not use LLMs for arithmetic. The agent is a single workflow with explicit services: context builder, prompt/settings storage, and orchestrator.

**Tech Stack:** Rails 8, PostgreSQL jsonb, ActiveStorage, Sidekiq, parser_worker Python, Docker Compose, Minitest, Playwright smoke.

---

## Scope

Iteration 1 covers:

- Agent persistence: `AgentSetting`, `AgentConversation`, `AgentMessage`, `AgentToolCall`.
- Root workspace: chat, context panel, quick actions, navigation.
- Chat send and clear.
- Agent settings page.
- Human-readable statuses in primary UI.
- Program-name fallback changed to `Название не определено`.
- Multi-tenant guardrails for touched document/program/change-set routes.

Out of scope for this iteration:

- Full DOCX tree parser.
- KnowledgeChunk persistence and embeddings.
- Real ChangeSet generation from XLSX/PDF.
- DOCX patch/export.
- OpenRouter function calling.

## Task 0: Preserve Task File

**Files:**
- Create: `CODEX_TASK_02_CHAT_AGENT_REFACTOR.md`
- Modify: `WORKLOG.md`

- [x] **Step 1: Copy the new task file into the project root**

Run:

```bash
cp /Users/aleksandrzagrekov/Downloads/CODEX_TASK_02_CHAT_AGENT_REFACTOR.md /Users/aleksandrzagrekov/Desktop/Municipal/CODEX_TASK_02_CHAT_AGENT_REFACTOR.md
```

Expected: root contains `CODEX_TASK_02_CHAT_AGENT_REFACTOR.md`.

## Task 1: RED Tests For Iteration 1

**Files:**
- Create: `rails_app/test/integration/agent_workspace_test.rb`
- Create: `rails_app/test/integration/agent_settings_test.rb`
- Create: `rails_app/test/integration/multi_tenant_access_test.rb`
- Create: `rails_app/test/services/reconciliation_builder_test.rb`
- Modify: `rails_app/test/integration/user_flow_test.rb`

- [x] **Step 1: Write failing tests**

Tests must assert:

- root shows `Чат с агентом`, `Контекст агента`, quick actions and no `Объяснить расхождения через OpenRouter`;
- posting `agent_messages#create` adds user and assistant messages;
- `clear_agent_chat` removes messages but keeps uploaded documents;
- `agent_settings#update` persists prompt, model and numeric/boolean settings;
- cross-organization document access returns forbidden/not found;
- `ReconciliationBuilder` creates or reuses `Название не определено` when parsed DOCX has no program name.

- [x] **Step 2: Run tests and verify RED**

Run:

```bash
docker-compose exec -T -e RAILS_ENV=test -e DATABASE_URL=postgres://postgres:postgres@postgres:5432/municipal_agent_test web bundle exec rails test test/integration/agent_workspace_test.rb test/integration/agent_settings_test.rb test/integration/multi_tenant_access_test.rb test/services/reconciliation_builder_test.rb
```

Expected: FAIL because routes/models/controllers do not exist yet.

## Task 2: Agent Persistence

**Files:**
- Create: `rails_app/db/migrate/20260508220000_create_agent_chat_schema.rb`
- Create: `rails_app/app/models/agent_setting.rb`
- Create: `rails_app/app/models/agent_conversation.rb`
- Create: `rails_app/app/models/agent_message.rb`
- Create: `rails_app/app/models/agent_tool_call.rb`
- Modify: `rails_app/app/models/organization.rb`

- [x] **Step 1: Add migration**

Create four tables exactly as required by Iteration 1 with jsonb defaults and organization/user foreign keys.

- [x] **Step 2: Add models and defaults**

`AgentSetting.for_organization!(organization)` must create the default system prompt, model ids and settings. `AgentConversation.active_for!(organization:, user:)` must create a conversation and welcome assistant message when empty.

- [x] **Step 3: Run migration and model tests**

Run:

```bash
docker-compose exec -T web bundle exec rails db:migrate
docker-compose exec -T -e RAILS_ENV=test -e DATABASE_URL=postgres://postgres:postgres@postgres:5432/municipal_agent_test web bundle exec rails db:prepare
```

## Task 3: Agent Services And Routes

**Files:**
- Create: `rails_app/app/services/agent_context_builder.rb`
- Create: `rails_app/app/services/agent_orchestrator.rb`
- Create: `rails_app/app/helpers/status_helper.rb`
- Create: `rails_app/app/controllers/agent_workspace_controller.rb`
- Create: `rails_app/app/controllers/agent_messages_controller.rb`
- Create: `rails_app/app/controllers/agent_conversations_controller.rb`
- Modify: `rails_app/config/routes.rb`

- [x] **Step 1: Add routes**

Root becomes `agent_workspace#show`. Add `agent_messages#create`, `clear_agent_chat`, and `agent_settings`.

- [x] **Step 2: Add context builder**

Context JSON must include organization, procedure status, active program, change sources, latest ChangeSet, and agent settings.

- [x] **Step 3: Add orchestrator**

Orchestrator saves user message, detects quick action, creates an explicit tool-call record, and saves an assistant response. It must not calculate money through LLM.

## Task 4: Workspace UI

**Files:**
- Create: `rails_app/app/views/agent_workspace/show.html.erb`
- Modify: `rails_app/app/views/layouts/application.html.erb`
- Modify: `rails_app/app/views/dashboard/index.html.erb` only if kept as legacy page
- Modify: `rails_app/test/integration/user_flow_test.rb`

- [x] **Step 1: Replace root dashboard**

Show chat on the left and context panel on the right. Add quick actions:

- `Загрузить порядок`
- `Загрузить программу`
- `Добавить документы изменений`
- `Провести анализ`
- `Создать проект изменений`
- `Проверить контрольные суммы`
- `Сформировать DOCX`

- [x] **Step 2: Remove debug OpenRouter action**

Primary UI must not show `Объяснить расхождения через OpenRouter`.

- [x] **Step 3: Hide raw statuses**

Use the status helper for user-visible status labels.

## Task 5: Agent Settings UI

**Files:**
- Create: `rails_app/app/controllers/agent_settings_controller.rb`
- Create: `rails_app/app/views/agent_settings/show.html.erb`

- [x] **Step 1: Add settings form**

Fields: system prompt, primary model, fast model, temperature, match threshold, money tolerance, use knowledge base, use chat history, auto apply exact matches, show technical statuses.

- [x] **Step 2: Save settings organization-scoped**

Never store secrets in these settings.

## Task 6: Minimal Navigation Pages And Tenant Guards

**Files:**
- Create or modify: `rails_app/app/controllers/source_documents_controller.rb`
- Create: `rails_app/app/views/source_documents/index.html.erb`
- Create: `rails_app/app/views/source_documents/show.html.erb`
- Create or modify: `rails_app/app/controllers/knowledge_chunks_controller.rb`
- Create: `rails_app/app/views/knowledge_chunks/index.html.erb`
- Modify: `rails_app/app/controllers/change_sets_controller.rb`
- Modify: `rails_app/app/controllers/programs_controller.rb`
- Modify: `rails_app/app/controllers/program_versions_controller.rb`
- Modify: `rails_app/app/controllers/reconciliations_controller.rb`
- Modify: `rails_app/app/controllers/documents_controller.rb`

- [x] **Step 1: Add minimal documents page**

Separate procedure, current program, change sources and generated documents.

- [x] **Step 2: Tenant-scope lookups**

Replace direct `find(params[:id])` with organization-scoped queries for touched controllers.

## Task 7: Reconciliation Fallback Fix

**Files:**
- Modify: `rails_app/app/services/reconciliation_builder.rb`

- [x] **Step 1: Remove invented program fallback**

If parsed DOCX does not contain a program name, use `Название не определено`.

## Task 8: Verification And Documentation

**Files:**
- Modify: `README.md`
- Modify: `WORKLOG.md`

- [x] **Step 1: Run required checks**

Run:

```bash
docker-compose config --quiet
docker-compose exec -T -e RAILS_ENV=test -e DATABASE_URL=postgres://postgres:postgres@postgres:5432/municipal_agent_test web bundle exec rails test
./.venv/bin/python -m pytest parser_worker
find rails_app -name '*.rb' -print0 | xargs -0 -n 1 ruby -c
./.venv/bin/python -m compileall -q parser_worker/municipal_agent parser_worker/cli.py
```

- [x] **Step 2: Browser smoke**

Verify login, root workspace, chat, context panel, settings save, clear chat, documents link and no console errors.

- [x] **Step 3: Update WORKLOG and README**

Record changed files, tests, servers, browser checks, risks and next steps.
