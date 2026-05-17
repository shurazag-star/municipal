# Final Product Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** довести Municipal до сценария, где пользователь через чат получает проверенную новую редакцию DOCX и отчет без debug-терминов.

**Architecture:** сохранить текущий фундамент Rails + parser worker + ChangeSet + DOCX patcher. Добавить явный слой `AgentToolRegistry` для инструментов и `AgentResponseComposer` для человекочитаемых ответов и UI-карточек. Финальные файлы показывать только если export прошел post-export validation и LibreOffice render.

**Tech Stack:** Rails 8, Minitest, ActiveStorage, PostgreSQL/Redis/Docker Compose, Python parser worker, pypdf, Tesseract/poppler, LibreOffice.

---

### Task 1: Chat Safety And Response Layer

**Files:**
- Modify: `rails_app/app/controllers/agent_workspace_controller.rb`
- Modify: `rails_app/app/views/agent_workspace/show.html.erb`
- Create: `rails_app/app/views/agent_workspace/_assistant_cards.html.erb`
- Create: `rails_app/app/services/agent_tool_registry.rb`
- Create: `rails_app/app/services/agent_response_composer.rb`
- Modify: `rails_app/app/services/agent_orchestrator.rb`
- Test: `rails_app/test/integration/agent_workspace_test.rb`
- Test: `rails_app/test/services/agent_response_composer_test.rb`

- [x] Save CODEX_TASK_04 in project root.
- [x] RED: system/tool messages are not rendered.
- [x] RED: user-facing agent response contains no forbidden technical terms.
- [x] GREEN: filter chat messages to `user`/`assistant`.
- [x] GREEN: route tool execution through `AgentToolRegistry`.
- [x] GREEN: compose clean Russian answers through `AgentResponseComposer`.
- [x] GREEN: render assistant download cards from message metadata.

### Task 2: Export Readiness And Download Cards

**Files:**
- Modify: `rails_app/app/models/change_set.rb`
- Modify: `rails_app/app/services/change_set_application_service.rb`
- Modify: `rails_app/app/controllers/change_sets_controller.rb`
- Modify: `rails_app/app/controllers/source_documents_controller.rb`
- Modify: `rails_app/app/views/source_documents/index.html.erb`
- Test: `rails_app/test/services/change_set_application_service_test.rb`
- Test: `rails_app/test/integration/agent_workspace_test.rb`

- [x] RED: invalid export does not expose final DOCX button.
- [x] RED: successful chat export renders DOCX/report buttons.
- [x] GREEN: add `export_failed` and `needs_manual_review` statuses.
- [x] GREEN: mark final export only after validator status is ready.
- [x] GREEN: list generated documents in `/documents`.

### Task 3: Model Sync And Knowledge Base Use

**Files:**
- Modify: `rails_app/app/controllers/admin/openrouter_settings_controller.rb`
- Modify: `rails_app/app/services/agent_intent_router.rb`
- Modify: `rails_app/app/services/agent_tool_registry.rb`
- Modify: `rails_app/app/services/agent_response_composer.rb`
- Test: `rails_app/test/integration/admin_openrouter_settings_test.rb`
- Test: `rails_app/test/integration/agent_workspace_test.rb`

- [x] RED: admin OpenRouter model change updates `AgentSetting` and next chat LLM run uses the new model.
- [x] RED: procedure question invokes `search_knowledge_base`.
- [x] GREEN: synchronize `AgentSetting` from admin model settings.
- [x] GREEN: add `search_knowledge_base` intent and response.

### Task 4: PDF Agreement Modes And Source Conflicts

**Files:**
- Modify: `parser_worker/municipal_agent/agreement_pdf_parser.py`
- Modify: `rails_app/app/services/external_source_matcher.rb`
- Modify: `rails_app/app/services/change_set_builder.rb`
- Create: `rails_app/app/services/source_conflict_detector.rb`
- Modify: `rails_app/app/services/analysis_session_runner.rb`
- Test: `parser_worker/tests/test_agreement_pdf_parser.py`
- Test: `rails_app/test/services/source_conflict_detector_test.rb`
- Test: `rails_app/test/services/analysis_session_runner_test.rb`

- [x] RED: parser distinguishes `absolute`, `delta_plus`, `delta_minus`, `transfer`, `zeroing`, `unknown`.
- [x] RED: XLSX/PDF conflict creates confirmation-required conflict item.
- [x] GREEN: include amount mode fields in PDF payload.
- [x] GREEN: compute final values from deltas in Rails code, not LLM.
- [x] GREEN: mark conflicts and low-confidence/unknown PDF rows for user choice.

### Task 5: Full Validation, Multimunicipality, Docs

**Files:**
- Modify: `rails_app/app/services/post_export_docx_validator.rb`
- Modify: `rails_app/app/services/change_set_application_service.rb`
- Modify: `README.md`
- Modify: `агент.md`
- Modify: `WORKLOG.md`
- Test: `rails_app/test/services/post_export_docx_validator_test.rb`
- Test: `rails_app/test/services/change_set_application_service_test.rb`

- [x] RED: local budget label never hard-codes `Шатура` for another organization.
- [x] GREEN: local budget label uses organization municipality name or neutral local-budget label.
- [x] GREEN: expose missing coordinate warnings as manual-review reasons.
- [x] Verify Rails targeted/full tests.
- [x] Verify parser targeted/full tests.
- [x] Verify browser smoke for chat flow and visible download cards.
- [x] Stop Docker services and check ports.
