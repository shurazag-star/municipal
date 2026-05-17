# AnalysisSession ChangeSet Iteration 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an end-to-end analysis session that matches parsed Excel/PDF change sources to the persisted program tree, creates a ChangeSet, and lets the user confirm disputed rows.

**Architecture:** Rails owns persisted analysis state, matching records, ChangeSet creation, confirmation policy, and UI. Parser worker remains the source of parsed payloads; LLM/agent quick actions only orchestrate deterministic services and do not calculate money or patch DOCX.

**Tech Stack:** Rails 8, PostgreSQL JSONB, Active Record enums/associations, Minitest integration/service tests, existing parser payloads.

---

### Task 1: Schema and Model

**Files:**
- Create: `rails_app/db/migrate/20260509010000_create_analysis_sessions_and_extend_change_items.rb`
- Create: `rails_app/app/models/analysis_session.rb`
- Modify: `rails_app/app/models/organization.rb`
- Modify: `rails_app/app/models/program_version.rb`
- Modify: `rails_app/app/models/change_set.rb`
- Modify: `rails_app/app/models/change_item.rb`

- [x] Write failing model/service tests that reference `AnalysisSession`, `ChangeSet#analysis_session`, and `ChangeItem#status`.
- [x] Run the focused tests and confirm they fail because the schema/model does not exist yet.
- [x] Add the migration from the spec: `analysis_sessions` with organization, user, program_version, status, goal, selected source ids, summary. Add optional `analysis_session_id` to `change_sets`. Add missing `change_items.explanation` and `change_items.status`.
- [x] Add associations and status enums.
- [x] Run migrations and focused tests until green.

### Task 2: Matching Services

**Files:**
- Create: `rails_app/app/services/external_source_matcher.rb`
- Create: `rails_app/app/services/analysis_session_runner.rb`
- Test: `rails_app/test/services/external_source_matcher_test.rb`
- Test: `rails_app/test/services/analysis_session_runner_test.rb`

- [x] Write RED tests for exact object-name match, unmatched Excel object requiring confirmation, and unsupported PDF payload being summarized without crashing.
- [x] Implement normalization, object candidate lookup, match confidence/status, and `MatchCandidate` persistence.
- [x] Run focused service tests until green.

### Task 3: ChangeSet Builder and Confirmation Policy

**Files:**
- Create: `rails_app/app/services/change_set_builder.rb`
- Modify: `rails_app/app/controllers/change_sets_controller.rb`
- Test: `rails_app/test/services/change_set_builder_test.rb`
- Test: `rails_app/test/integration/change_sets_test.rb`

- [x] Write RED tests showing a ChangeSet is created from source deltas, disputed rows require confirmation, empty/unconfirmed sets cannot be approved, and unapproved sets cannot be applied.
- [x] Implement builder from match candidates and source funding values to `ChangeItem` rows.
- [x] Fix controller confirmation to use real columns and require all disputed rows to be confirmed before approval.
- [x] Keep `apply` blocked from mutating DOCX/tree in this iteration.
- [x] Run focused tests until green.

### Task 4: Analysis UI and Agent Quick Actions

**Files:**
- Create: `rails_app/app/controllers/analysis_sessions_controller.rb`
- Create: `rails_app/app/views/analysis_sessions/show.html.erb`
- Modify: `rails_app/config/routes.rb`
- Modify: `rails_app/app/services/agent_orchestrator.rb`
- Modify: `rails_app/app/services/agent_context_builder.rb`
- Modify: `rails_app/app/views/agent_workspace/show.html.erb`
- Modify: `rails_app/app/views/change_sets/index.html.erb`
- Modify: `rails_app/app/views/change_sets/show.html.erb`
- Test: `rails_app/test/integration/analysis_sessions_test.rb`
- Test: `rails_app/test/integration/agent_workspace_test.rb`

- [x] Write RED tests for creating/running an analysis session from UI and for the agent quick action creating a real ChangeSet.
- [x] Add routes, controller, view, quick-action wiring, and context panel links.
- [x] Expand ChangeSet show to list object, year, source, old/new/delta, source reference, confidence, and confirmation buttons.
- [x] Run focused integration tests until green.

### Task 5: Verification and Documentation

**Files:**
- Modify: `README.md`
- Modify: `WORKLOG.md`

- [x] Run Rails migrations in the running Docker stack.
- [x] Run Rails test suite and parser worker test suite.
- [x] Open `http://localhost:3000` in browser, run analysis, open created ChangeSet, confirm a disputed row, and check console/runtime errors.
- [x] Update README and append WORKLOG entry with commands, browser checks, risks, and next steps.
