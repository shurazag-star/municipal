# 2026-05-13: real documents import and agent answer test

## Context
- Previous real-data run before automatic insertion produced 56 manual new-object rows.
- The new implementation can insert confirmed `new_object` rows into DOCX when the parent activity and DOCX coordinates are resolvable.
- The user asked to run the practical full test with the three real documents and verify the chat agent answers correctly.

## Expected Result
- Three real files are uploaded through the application UI and parsed by `ParseDocumentJob`.
- The agent chat runs analysis, creates a ChangeSet, reports meaningful counts, and does not pretend to apply unapproved changes.
- After approving the ChangeSet, the agent chat generates DOCX/report and reports updated cells, inserted objects, and remaining manual inserts.
- The result is compared against the old baseline of 56 manual rows.

## Test Suite Structure
- Smoke: upload DOCX/XLSX/PDF, parse all, see active program and parsed context.
- Behavioral: ask the agent to analyze documents, validate control sums, and generate DOCX after approval.
- Failure/guard: verify that DOCX generation is blocked before ChangeSet approval.
- Observability: inspect `AgentToolCall`, `AnalysisSession`, `ChangeSet.export_summary`, generated DOCX attachment, and report attachment.
- Artifact QA: extract generated DOCX text/tables and verify inserted-object rows are present when `inserted_count > 0`.

## Pass / Fail Criteria
- PASS if all three documents reach `parsed`, an analysis session completes, ChangeSet is created, agent responses include concrete statuses/counts, generated DOCX/report are attached, and `manual_insert_required_count` is lower than the previous 56 baseline or clearly explained by unresolved coordinates.
- FAIL if parsing fails, the agent gives only generic text for actionable requests, DOCX generation proceeds without approval, generated DOCX/report are missing, or inserted/manual counts are inconsistent with DB/report.

## Tools
- Docker Compose for app stack.
- Browser plugin for UI upload/chat checks.
- Rails runner for deterministic state inspection and approval.
- `python-docx` for structural DOCX verification.
- `agent_kb` test-agent template for evaluation structure.
