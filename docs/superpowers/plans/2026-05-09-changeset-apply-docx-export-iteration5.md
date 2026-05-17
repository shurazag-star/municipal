# ChangeSet Apply DOCX Export Iteration 5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply an approved ChangeSet by creating a new recalculated `ProgramVersion`, safely generating a patched DOCX copy, and producing a change report.

**Architecture:** Rails owns the persisted ChangeSet lifecycle, tree cloning, bottom-up recalculation, generated attachments, UI and agent orchestration. Python `parser_worker` owns deterministic DOCX table-cell patching via stored coordinates and never edits the original DOCX in place. LLM/OpenRouter is not used for money calculation or DOCX mutation.

**Tech Stack:** Rails 8, Active Record, Active Storage, Minitest, Python 3.12, python-docx 1.1.2, pytest, Docker Compose.

---

## Files

- Modify: `rails_app/app/models/change_set.rb`
- Modify: `rails_app/app/models/program_version.rb`
- Create: `rails_app/db/migrate/20260509020000_extend_change_sets_for_apply_export.rb`
- Create: `rails_app/app/services/change_set_application_service.rb`
- Create: `rails_app/app/services/change_set_report_builder.rb`
- Create: `rails_app/app/services/docx_patch_client.rb`
- Modify: `rails_app/app/controllers/change_sets_controller.rb`
- Modify: `rails_app/app/services/agent_orchestrator.rb`
- Modify: `rails_app/app/services/agent_context_builder.rb`
- Modify: `rails_app/app/views/change_sets/show.html.erb`
- Modify: `parser_worker/cli.py`
- Create: `parser_worker/municipal_agent/docx_patcher.py`
- Create: `parser_worker/tests/test_docx_patcher.py`
- Modify: `rails_app/test/integration/change_sets_test.rb`
- Create: `rails_app/test/services/change_set_application_service_test.rb`
- Modify: `rails_app/test/integration/agent_workspace_test.rb`
- Modify: `WORKLOG.md`

## Task 1: RED Tests for Apply/Export

- [x] Add Rails tests proving an unapproved ChangeSet cannot apply, an approved ChangeSet creates a new version, object funding changes, parent totals recalculate, generated DOCX/report attachments exist, and original DOCX bytes are unchanged.
- [x] Add parser worker test proving `patch-docx` updates a numeric cell by table/row/cell coordinates, opens with python-docx, and leaves the source file unchanged.
- [x] Run focused tests and confirm expected RED failures are about missing implementation.

## Task 2: Python DOCX Patcher

- [x] Implement `format_money_for_docx(amount_rub, source_cell_raw_value, unit="thousand_rub")` with rub-to-thousand conversion, comma decimal separator, original decimal precision, and original grouping separator style.
- [x] Implement `patch_docx(input_path, changes, output_path)` that loads the original DOCX, updates only addressed numeric table cells, saves a new DOCX, and returns applied/skipped details.
- [x] Add `patch-docx` CLI command accepting `--input`, `--changes`, and `--output`.
- [x] Run parser worker focused pytest until green.

## Task 3: Rails Apply Service

- [x] Add ChangeSet fields for `target_program_version_id`, `applied_at`, and `export_summary`.
- [x] Add Active Storage attachments on `ChangeSet`: `generated_docx_attachment` and `change_report_attachment`.
- [x] Implement `ChangeSetApplicationService`:
  - require `approved`;
  - require no unconfirmed disputed items;
  - clone the source program tree into a new `ProgramVersion`;
  - apply confirmed `amount_update` items to cloned leaves;
  - recalculate non-leaf funding totals bottom-up;
  - mark new object items as `MANUAL_INSERT_REQUIRED` in summary/report without unsafe DOCX insertion;
  - generate and attach patched DOCX/report;
  - mark ChangeSet `applied`.
- [x] Run Rails service tests until green.

## Task 4: UI and Agent Flow

- [x] Replace placeholder `apply`, `export_docx`, and `export_report` controller actions with real service calls and attachment downloads.
- [x] Update ChangeSet show page to display generated artifacts, target version, manual insert count, and clear disabled states.
- [x] Update agent quick action `Сформировать DOCX` to use the latest approved/applied ChangeSet and report the produced artifacts instead of returning a placeholder.
- [x] Add/adjust integration tests for UI and agent quick action.

## Task 5: Verification and Cleanup

- [x] Run `docker-compose config --quiet`.
- [x] Start stack only for verification with `docker-compose up -d --build`.
- [x] Run Rails DB prepare and full Rails tests in test env.
- [x] Run full parser worker pytest.
- [x] Run Ruby syntax checks and Python compile checks.
- [x] Browser smoke: login, open ChangeSet, apply approved project, confirm DOCX/report links, verify console has no errors.
- [x] Stop Docker services and confirm no listeners remain on `3000`, `5432`, `6379`.
- [x] Review final diff and append a WORKLOG entry.
