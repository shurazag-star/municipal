# CODEX TASK 09 — Fix wrong municipal DOCX generation: Excel is target state, not a patch list

## Critical finding
The agent-generated file `changeset-195-version-3.docx` is financially wrong. The user provided the correct result: `проект изменений МП_май_2026.docx`.

Independent parse results:

| File | 2026 passport total, rub | 2027 passport total, rub | 2028 passport total, rub |
|---|---:|---:|---:|
| Source March DOCX | 2,296,101,960.00 | 1,866,791,200.00 | 690,689,180.00 |
| Finance XLSX target | 2,253,220,255.91 | 1,776,791,196.12 | 780,689,180.00 |
| Correct May DOCX | 2,253,220,260.00 | 1,776,791,200.00 | 780,689,180.00 |
| Agent-generated DOCX | 5,492,083,000.00 | 3,467,821,870.00 | 1,029,790,930.00 |

The correct DOCX matches Excel within Word rounding tolerance (amounts are shown in thousand rubles with 2 decimals). The agent-generated DOCX is not close.

Also, the agent-generated passport table is internally invalid:

- Moscow Oblast source row total column = `3,736,797.28` thousand rubles, but year cells sum to `7,902,324.31` thousand rubles.
- Local budget row total column = `1,116,785.06` thousand rubles, but year cells sum to `2,087,371.49` thousand rubles.
- Program total column = `4,853,582.34` thousand rubles, but year cells sum to `9,989,695.80` thousand rubles.

The correct DOCX has all these totals internally consistent.

## Root causes to fix

### 1. XLSX is being treated as a partial patch, but it is a full target financial state
The Excel finance report is not just a list of additions. It is the current target financial model. For each object/group present in Excel, the target amounts by year/source should replace the old DOCX amounts for that object/group.

Current wrong behavior:

- `ChangeSetBuilder#create_amount_items!` only creates changes for entries present in Excel.
- If a year/source is missing in Excel, the old DOCX funding line remains untouched.
- Therefore old amounts that should become zero stay in the program and are added to new Excel amounts during bottom-up recalculation.

Concrete example:

Excel group `1000010247.5327942181` for “Реконструкция ВЗУ ... Туголесский Бор” has no 2026 amount. The correct May DOCX zeros/removes old 2026 funding for this object. The current agent leaves old 2026 values in place because no Excel entry exists for 2026, so no zeroing change is generated.

Required fix:

- Build an `ExternalTargetModel` from XLSX.
- For each matched object/group, compare the full key set:
  - years 2026–2030;
  - all budget sources;
  - existing DOCX lines and Excel lines.
- Generate zeroing changes for old DOCX lines that are absent or zero in Excel.
- Do not leave old funding lines simply because the Excel cell is blank/zero.

### 2. Missing/unmatched Excel groups are inserted on top of old DOCX instead of reconciling the full tree
Current code creates many `new_object` entries when it cannot match Excel groups. This adds Excel amounts while the old DOCX structure remains, causing double counting.

The correct result added very few structural nodes compared with the source:

- Source parsed nodes: 162;
- Correct May parsed nodes: 166;
- Agent-generated parsed nodes: 181.

The generated file over-inserted objects/rows, especially in the large table:

- Source table 6 rows: 296;
- Correct May table 6 rows: 302;
- Agent-generated table 6 rows: 331.

Required fix:

- Do not auto-insert every unmatched Excel group as a new object.
- First resolve by object code, then normalized object name, then parent activity + budget source + amount pattern.
- If still unresolved, classify as `unresolved`, not as an inserted object.
- Final DOCX must be blocked until unresolved financial groups are either mapped by the agent from evidence or explicitly excluded with a documented reason.

### 3. UNASSIGNED_RESIDUAL rows are being mishandled
The Excel report contains rows with object code `0000000000.0000000000`, e.g. rows 14, 16, 18, 20, 35, 42. These are not normal object rows.

Current wrong symptoms:

The HTML report shows “objects” that are just numbers:

- `7388096.53`
- `313196.01`
- `34386810.0`
- `23247950.0`

This is invalid. An object name must never be a money amount.

Required fix:

- Treat `UNASSIGNED_RESIDUAL` as residual/aggregate finance rows, not normal objects.
- Derive a safe label from the parent activity, not from the amount.
- Never allow numeric-only labels to be treated as valid target objects.
- Residual rows can only be applied if they make the parent/program totals match the Excel target and have a valid parent activity.
- Otherwise block as unresolved.

### 4. The validator compares the generated DOCX to the app's own flawed target model
`PostExportDocxValidator#target_year_totals` uses the target DB tree as expected totals. If the target DB tree is wrong, validation still passes.

Required fix:

Add `ExternalFinancialTargetValidator` and make it mandatory for XLSX scenarios:

- expected totals = `program_totals` or `final_totals` from XLSX;
- actual totals = re-parsed generated DOCX `passport_totals_by_year`;
- expected source totals = derived from XLSX source columns where available;
- actual source totals = re-parsed generated DOCX `passport_amounts`;
- total columns in the passport must equal the sum of year columns.

A generated DOCX must be final/exportable only when:

1. generated passport totals match Excel target within Word rounding tolerance;
2. generated passport source totals match Excel-derived source totals;
3. passport total columns are internally consistent;
4. no unresolved groups remain;
5. no numeric-only object labels are present in the report or generated tree;
6. LibreOffice render passes.

The current `changeset-195-version-3.docx` must fail validation.

### 5. Passport total column is not updated
`DocxPatchPlanBuilder#add_passport_total_updates` updates passport year cells, but there is no update for the passport “Всего” column cells.

Required fix:

- Extend DOCX parser to capture passport total-column coordinates for:
  - each source row;
  - the final “Всего, в том числе по годам” row.
- Patch those cells after recalculation.
- Add tests that total column equals sum of 2026–2030 columns.

### 6. Report can display a numeric amount as object name
`ChangeSetReportBuilder#row_for` falls back to `item.new_value`, which for amount updates is often a numeric amount. This creates fake object labels in the report.

Required fix:

- Never use `item.new_value` as an object label for amount updates.
- If the target node/path is missing, show `Не определено` and mark the row as unresolved.
- Block final export if any applied row has no valid target hierarchy.

### 7. Agent instruction and workflow still allow old manual-confirmation logic
The system prompt still says to require user confirmation. The user-facing workflow must be autonomous.

Required fix:

- Replace the default agent prompt with the English prompt from CODEX_TASK_08.
- The agent answers in Russian.
- Normal users should not confirm 56 rows.
- If the system cannot prove a mapping, it blocks final export and explains the unresolved evidence issue.

## Acceptance tests using real files
Create a deterministic E2E regression test with:

- source DOCX: `проект изменений МП_март_2026 (10).docx`
- finance XLSX: `Отчет_о_финансировании_мероприятий_целевых_программ+_Расширенный.xlsx`
- correct DOCX: `проект изменений МП_май_2026.docx`

The test must assert:

### Passport totals
Generated final DOCX must match the correct May DOCX and Excel target within tolerance:

- 2026: around `2,253,220,260.00` rub in DOCX / `2,253,220,255.91` rub in Excel;
- 2027: around `1,776,791,200.00` rub in DOCX / `1,776,791,196.12` rub in Excel;
- 2028: exactly `780,689,180.00` rub.

### Passport source totals
Generated DOCX should match correct May source rows:

- Moscow Oblast budget:
  - 2026: `1,810,681,600.00` rub;
  - 2027: `1,254,541,650.00` rub;
  - 2028: `623,350,950.00` rub.
- Local budget:
  - 2026: `442,538,660.00` rub;
  - 2027: `522,249,550.00` rub;
  - 2028: `157,338,230.00` rub.

### Internal passport consistency
For every passport source row and the final total row:

`Всего` column = sum of 2026 + 2027 + 2028 + 2029 + 2030.

### Zeroing behavior
If a matched object has an old DOCX amount for a year/source that is absent in Excel, generate a zeroing update.

Use “Реконструкция ВЗУ ... Туголесский Бор” as a fixture: old 2026 values must not remain if Excel has no 2026 values for that object.

### No false final export
The current wrong file `changeset-195-version-3.docx` must fail validation with explicit errors.

### No numeric object labels
Report rows and generated tree must not contain applied object labels that match only a number/money amount.

## Implementation direction
Recommended services/classes:

- `ExternalTargetModelBuilder` — builds authoritative target state from XLSX/PDF change sources.
- `FullStateReconciler` — compares source DOCX tree to external target state, including zeroing missing lines.
- `ResidualGroupResolver` — handles `UNASSIGNED_RESIDUAL` rows safely.
- `ExternalFinancialTargetValidator` — validates generated DOCX against XLSX/PDF target, not only against DB target.
- `PassportColumnCoordinateExtractor` — captures total-column coordinates.
- `FinalExportGate` — blocks download cards unless every validation passes.

## Completion criteria
This task is complete only when:

- the agent no longer produces the inflated passport totals seen in `changeset-195-version-3.docx`;
- generated DOCX matches the correct May DOCX passport totals and Excel target totals;
- old absent-year funding is zeroed/replaced correctly;
- unmatched/residual rows do not become fake objects;
- the passport total column is updated;
- the report is truthful and does not show numeric pseudo-objects;
- user-facing chat says clearly whether the document is final or blocked;
- tests prove the current bad output cannot pass.
