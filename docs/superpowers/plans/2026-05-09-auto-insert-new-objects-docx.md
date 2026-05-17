# 2026-05-09: auto-insert new objects into generated DOCX

## Context
- Current Iteration 5 exports a safe DOCX but leaves every `new_object` ChangeItem as manual insertion.
- Real data shows 56 new-object rows; this blocks the user because the agent cannot produce a ready document.
- The implementation must preserve the original DOCX attachment, create a new program version, write new `ProgramNode` / `FundingLine` records, and generate DOCX rows only when a parent activity and table coordinates are available.

## Expected Result
- Confirmed `new_object` items with a resolvable parent activity are inserted into the target program tree and generated DOCX.
- `manual_insert_required_count` only counts items that truly cannot be inserted automatically.
- Chat command / quick action "Сформировать DOCX" applies the same path and reports inserted objects.

## Files / Modules
- `parser_worker/municipal_agent/docx_patcher.py`
- `parser_worker/cli.py`
- `parser_worker/tests/test_docx_patcher.py`
- `rails_app/app/services/change_set_application_service.rb`
- `rails_app/app/services/change_set_report_builder.rb`
- `rails_app/app/services/agent_orchestrator.rb`
- `rails_app/test/services/change_set_application_service_test.rb`
- `rails_app/test/integration/agent_workspace_test.rb`
- possibly `rails_app/app/services/external_source_matcher.rb` and its tests for source references / matching metadata

## Plan
1. Add failing parser test for inserting DOCX object rows while preserving source bytes.
2. Add failing Rails service test for confirmed `new_object` -> new target node, funding lines, generated DOCX text, and zero manual count.
3. Add failing chat-agent integration assertion that "Сформировать DOCX" reports inserted objects through the tool result.
4. Implement patch payload shape: `cell_updates` + `insert_objects`, backward-compatible with the old array payload.
5. Implement deterministic DOCX row insertion by cloning template rows and filling display number, object name, period, funding source labels, totals, and yearly cells.
6. Implement Rails grouping of `new_object` items, parent resolution from external parent activity code, ProgramNode/FundingLine creation, insert payload generation, and export summary.
7. Update report statuses so inserted objects are not shown as manual.
8. Run focused tests, then broader Rails/parser tests as time allows.
9. Run browser smoke through the chat agent, then stop Docker and check ports.

## Risks / Non-goals
- This does not redesign the parser or the entire matching engine.
- Existing amount cell updates must remain coordinate-safe and should be applied before row insertion.
- Rows with unresolved parent coordinates still remain manual and must be visible in the report.
- DOCX formatting is cloned from an adjacent existing row; exact semantic merging of complex Word table structures is out of scope for this iteration.
