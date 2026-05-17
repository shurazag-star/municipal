# 2026-05-13 — снятие ограничений: visual DOCX render, OCR PDF, agent evals

## Цель

Снять текущие ограничения:

- `soffice` отсутствует, поэтому DOCX не проходит визуальный render QA;
- `pdf_agreement` работает только по текстовому слою PDF;
- агент должен давать проверяемо надежный результат по intent/tool выбору.

## Изменения

1. Docker/infrastructure:
   - добавить LibreOffice, poppler, fonts в Rails image;
   - добавить poppler, tesseract, русский и английский OCR data в parser worker image;
   - не хранить секреты и не менять `.env`.
2. Visual DOCX validation:
   - добавить `DocxVisualRenderer`;
   - конвертировать DOCX в PDF через `soffice --headless`;
   - проверять PDF через `pdfinfo`;
   - рендерить preview PNG через `pdftoppm`;
   - включить результат в `PostExportDocxValidator`.
3. OCR для `pdf_agreement`:
   - если `pypdf.extract_text()` дает мало текста, рендерить PDF страницы через `pdftoppm`;
   - прогонять страницы через `tesseract -l rus+eng`;
   - извлекать changes из OCR-текста тем же deterministic parser;
   - если OCR tooling отсутствует, возвращать понятное warning/error, а не молча считать PDF пустым.
4. Agent eval suite:
   - добавить тестовый набор фраз с ожидаемым intent/tool;
   - покрыть happy path, ambiguity path и safety path;
   - считать pass rate только по наблюдаемым tool decisions.

## Проверки

- [x] RED/GREEN unit tests для новых сервисов.
- [x] Полный parser worker test suite.
- [x] Полный Rails test suite.
- [x] Docker rebuild и runtime checks:
  - [x] `soffice --headless --version`;
  - [x] `pdftoppm -h`;
  - [x] `tesseract --list-langs`.
- [x] Smoke-проверка real DOCX через LibreOffice render: `valid`, 72 страницы, 1 preview.

## Риски

- Установка LibreOffice увеличила Docker image.
- OCR качество зависит от качества скана; для плохих сканов агент должен просить ручную проверку.
- “100%” для произвольной человеческой фразы недостижимо математически; реализовано 100% безопасное поведение на покрытых eval cases: правильный tool или контролируемое уточнение без опасных действий.
