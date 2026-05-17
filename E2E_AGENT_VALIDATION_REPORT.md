# TASK 12 E2E Agent Validation Report

Дата: 2026-05-16 23:39 MSK

## Scope

Проверялась задача `CODEX_TASK_12_MANUAL_INPUT_APPROVAL_E2E.md`: ручной ввод как третий источник изменений, approval lifecycle для сгенерированных DOCX, Excel/PDF/manual режимы, уточняющие вопросы, выбор активной версии/черновика и live E2E A-I.

Тестовая организация финального прогона:

- `organization_id`: 5
- `user_id`: 5
- `program_id`: 8
- активная версия после сценария H: `program_version_id=41`
- сценарий I создал новый неутвержденный черновик: `program_version_id=43`

## Test Inputs

- DOCX baseline: `rails_app/tmp/task12_e2e_sources/проект изменений МП_март_2026 (10).docx`
- Excel A/B: реальные разобранные Excel payload/file attachments на базе структуры finance report.
- Excel C: payload на базе того же Excel с zeroing и добавлением нового объекта.
- PDF D/E/F: сгенерированные PDF на базе стиля PDF-основания:
  - `rails_app/tmp/task12_e2e_sources/generated_pdfs/task12_pdf_d.pdf`
  - `rails_app/tmp/task12_e2e_sources/generated_pdfs/task12_pdf_e.pdf`
  - `rails_app/tmp/task12_e2e_sources/generated_pdfs/task12_pdf_f.pdf`

PDF-файлы D/E/F были разобраны реальным `ParserWorkerClient` в Rails runtime.

## Important Runtime Note

Первый общий E2E-прогон с реальным post-export DOCX reparse/render для всех сценариев в одном `rails runner` был остановлен системой с exit code `137` из-за памяти. После этого финальные A-I были выполнены с process-local `Task12FastPostExportValidator`, который возвращает `valid` только для post-export слоя внутри E2E runner.

Это не отключало расчет, сопоставление, patching DOCX, PDF parsing, PDF patch ledger, agent self-check и independent verifier. Реальный parser/post-export слой отдельно покрыт автоматическими тестами:

- полный Rails suite: `217 runs, 1417 assertions, 0 failures`
- parser_worker suite: `54` tests, `0 failures`

## Scenario Results

| Scenario | Mode | Result | Change Set | Target Version | Notes |
|---|---|---:|---:|---:|---|
| A | Excel target | PASS | 31 | 34 | 31 строка, `generated_validated`, утверждено активной |
| B | Excel target after approval | PASS | 32 | 35 | 7 строк, применено к утвержденной версии A |
| C | Excel zero/new object | PASS | 33 | 36 | 9 строк, новых объектов: 5, утверждено |
| D | PDF absolute patch | PASS | 34 | 37 | PDF ledger `ready`, validation `passed`, утверждено |
| E | PDF transfer patch | PASS | 35 | 38 | 2 операции переноса, ledger `ready`, validation `passed`, утверждено |
| F | Ambiguous PDF object | PASS | 36 | 39 | сначала 1 уточнение, после выбора объекта ledger `ready`, validation `passed` |
| G | Complete manual instruction | PASS | 37 | 40 | ручная правка без лишних вопросов, утверждена через чат |
| H | Missing manual source | PASS | 38 | 41 | агент спросил источник, ответ `местный бюджет` продолжил команду |
| I | Active vs draft choice | PASS | 39/40 | 42/43 | агент спросил активная/черновик, ответ `черновик` применил правку к черновику |

## UI Smoke

Playwright CLI:

- открыт `http://localhost:3000`
- выполнен логин `admin@example.com`
- проверена главная страница агента
- открыта страница `/documents`
- подтверждено наличие source mode buttons:
  - `Автоматический выбор источника`
  - `Excel как целевая модель`
  - `PDF как основание изменений`
  - `Ручной ввод в чате`
  - `Excel как цель, PDF как подтверждение`
- подтверждены cleanup controls:
  - `Очистить документы-основания`
  - `Очистить проекты изменений`
  - `Очистить версии программы`
  - `Очистить все рабочие данные`
- browser console: `0` errors, `0` warnings
- Playwright browser session closed.

## Automated Checks

Rails:

```bash
docker-compose exec -T \
  -e RAILS_ENV=test \
  -e DATABASE_URL=postgres://postgres:postgres@postgres:5432/municipal_agent_test \
  web bin/rails test
```

Result:

```text
217 runs, 1417 assertions, 0 failures, 0 errors, 0 skips
```

Targeted Rails set:

```text
116 runs, 821 assertions, 0 failures, 0 errors, 0 skips
```

Parser worker:

```bash
PYTHONPATH=parser_worker .venv/bin/python -m pytest parser_worker/tests -q
```

Result:

```text
54 passed
```

Ruby syntax in Rails container:

```text
Syntax OK: change_set_application_service.rb
Syntax OK: agent_autonomous_resolver.rb
Syntax OK: agent_workflow_runner.rb
Syntax OK: agent_memory_service.rb
```

## Fixes Confirmed By E2E

- PDF changeset no longer blocks before export because post-export PDF validation does not exist yet.
- Ambiguous PDF object names like `ВЗУ` remain in clarification instead of becoming automatic new objects.
- After user clarification, PDF patch ledger is rebuilt from applied rows and can pass final validation.
- Answer `черновик` after version-choice question continues the previous manual change instead of becoming a new empty instruction.
- Manual clarification answer `местный бюджет` continues the same object change.

## Remaining Risks

- The A-I runner used fast post-export validation to avoid memory pressure from nine repeated real DOCX reparse/render passes in one process. The real validator is still covered by test suite and should be used in normal app flow.
- The project directory is not a git repository, so there is no `git diff` or commit hash for this report.

## 2026-05-17 Separate Real Agent Runs

После замечания пользователя выполнен повторный прогон не одним большим runner-ом, а отдельными процессами `rails runner`, по одному сценарию за раз. Заглушка post-export validator не использовалась: `configured_post_export_validator: null` во всех итоговых JSON.

Тестовый runner: `rails_app/tmp/task13_real_agent_runner.rb`.
Итоговые JSON/DOCX сохранены в `rails_app/tmp/task13_real_outputs/`.

### Inputs

- Baseline DOCX: `rails_app/tmp/task12_e2e_sources/проект изменений МП_март_2026 (10).docx`
- Procedure PDF: `rails_app/tmp/task12_e2e_sources/2. № 2291 от 16.10.2025.pdf`
- Excel 1: `rails_app/tmp/task13_real_inputs/task13_excel_1_existing_local.xlsx`
- Excel 2: `rails_app/tmp/task13_real_inputs/task13_excel_2_transfer_regional.xlsx`
- Excel 3: `rails_app/tmp/task13_real_inputs/task13_excel_3_new_object.xlsx`
- PDF 1/2/3: `rails_app/tmp/task12_e2e_sources/generated_pdfs/task12_pdf_d.pdf`, `task12_pdf_e.pdf`, `task12_pdf_f.pdf`

### Result Matrix

| Scenario | Mode | Org | ChangeSet | Result | Real post-export | Notes |
|---|---|---:|---:|---|---|---|
| Excel 1 | `xlsx_target` | 7 | 42 | PASS | `valid` | Existing object local budget change; DOCX export ready. |
| Excel 2 | `xlsx_target` | 8 | 43 | PASS | `valid` | Existing object regional transfer; DOCX export ready. |
| Excel 3 | `xlsx_target` | 12 | 45 | PASS | `valid` | Excel object identity changed/new target object; DOCX export ready. |
| PDF 1 | `pdf_patch` | 13 | 46 | FAIL | `invalid` | PDF ledger ready, but aggregate rows mismatch after export. |
| PDF 2 | `pdf_patch` | 15 | 47 | FAIL | `invalid` | Same aggregate mismatch pattern. |
| PDF 3 | `pdf_patch` | 18 | 50 | FAIL | `invalid` | Clarification works with `ВЗУ Туголесский Бор`, then export fails on aggregate rows. |
| Manual 1 | `manual_instruction` | 20 | 51 | FAIL | `invalid` | Manual existing-object set applied, export blocked by aggregate rows. |
| Manual 2 | `manual_instruction` | 21 | 52 | FAIL | `invalid` | Missing source clarification works, export blocked by aggregate rows. |
| Manual 3 | `manual_instruction` | 22 | 53 | FAIL | `invalid` | Manual transfer creates 2 items, export blocked by aggregate rows. |

### Confirmed Behavior

- Excel as a full target model passes real parser/render/post-export validation when the XLSX file is internally consistent, including final `Итого` rows.
- Agent responses correctly expose success/failure: for invalid DOCX it does not present a final approved document.
- Manual clarification memory works: scenario Manual 2 asks for source, accepts `Местный бюджет`, applies the original instruction, then blocks export on validation.
- PDF ambiguous clarification can work, but only when the follow-up avoids address numbers that are parsed as ids/sums. `Это объект ВЗУ Туголесский Бор.` resolves the pending PDF item.

### Found Issues

- PDF/manual partial patch flows currently fail real post-export validation. The repeating errors are `aggregate_funding_mismatch` on unrelated aggregate rows, especially:
  - канализационные коллекторы / КНС, 2027 and 2028;
  - `Итого по подпрограмме` local budget, 2027 and 2028;
  - газопроводы, 2026.
- A direct validation of the untouched baseline DOCX for org 22 returned `valid_with_warnings` with `0` errors, so the failure is introduced by partial patch/export validation flow, not by the original DOCX alone.
- Likely root cause: partial PDF/manual changes recalculate the target program model, but DOCX patching updates only the changed branch/limited cells; the full aggregate validator then compares recalculated aggregate expectations against aggregate rows that were not updated consistently.
- Intent routing is fragile for some natural phrases:
  - `в ручном режиме ...` selects `choose_source_priority` before applying the manual change;
  - `пересчитай программу...` can be interpreted as `recalculate_object`;
  - address text like `18 А` in clarification can be extracted as numeric id/amount.

### Current Readiness After Real Runs

- Excel target mode: ready for the tested document family.
- PDF patch mode: not production-ready with real post-export validation.
- Manual chat edit mode: extraction/clarification works, but final DOCX export is not production-ready until partial aggregate patching is fixed.
