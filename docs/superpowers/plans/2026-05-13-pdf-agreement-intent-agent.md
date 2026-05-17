# 2026-05-13 — pdf_agreement flow и LLM intent/tool чат

## Цель

Закрыть пункты 4 и 5 из `CODEX_TASK_03_READY_EXPORT_AND_AGENT_FIXES.md`:

- загрузка `pdf_agreement` должна проходить через parser worker, сохранять структурированный `parsed_payload["changes"]` и создавать ChangeSet;
- чат должен выбирать действие через LLM intent/tool схему, а не только через ключевые слова, с безопасным deterministic fallback.

## Контекст

- Rails уже умеет сопоставлять структурированный `pdf_agreement.parsed_payload["changes"]` через `ExternalSourceMatcher`.
- Сейчас `ParserWorkerClient::COMMANDS` не содержит `pdf_agreement`.
- Сейчас `parser_worker/cli.py` не содержит команды `parse-agreement-pdf`.
- Сейчас `AgentOrchestrator` выбирает действия по строковым includes.
- Денежные вычисления должны оставаться в deterministic code, не в LLM.

## Изменения

1. Добавить RED-тесты:
   - parser worker извлекает изменения из текста PDF-соглашения и возвращает стабильный JSON;
   - CLI имеет команду `parse-agreement-pdf`;
   - Rails `ParserWorkerClient` вызывает эту команду для `pdf_agreement`;
   - агент понимает свободные команды: `выгрузи новую редакцию`, `подготовь отчет`, `что поменялось по Черустям`, `почему в 2028 сумма стала больше`, `покажи ручную проверку`.
2. Реализовать `agreement_pdf_parser.py`:
   - deterministic text extraction через `pypdf.PdfReader`;
   - chunking страниц;
   - best-effort regex extraction объекта, года, источника, старой/новой суммы, delta, page/evidence/confidence;
   - совместимые поля для Rails: `source_type`, `amount_rub`, `page_number`, `evidence_text`.
3. Подключить parser:
   - `parse-agreement-pdf` в CLI;
   - `pdf_agreement => parse-agreement-pdf` в Rails client;
   - `parse_pdf_agreement` в legacy `agent_tools.py` без pending-заглушки.
4. Реализовать `AgentIntentRouter`:
   - использовать `AgentSetting.system_prompt`, контекст и явную JSON Schema intent;
   - вызывать OpenRouter structured output, если ключ настроен;
   - записывать `LlmRun`;
   - при ошибке/низкой уверенности использовать deterministic fallback;
   - возвращать только разрешенные tool intents.
5. Расширить `AgentOrchestrator`:
   - исполнять intent из router;
   - добавить реальные ответы/tools для `show_changeset`, `explain_change`, `show_pending`, `list_generated_documents`;
   - сохранить существующие быстрые действия.
6. Проверки:
   - `pytest parser_worker`;
   - Rails unit/integration tests на затронутые сервисы;
   - по возможности browser smoke на чат.

## Риски

- Без реального PDF-соглашения parser остается deterministic best-effort и проверяется на синтетическом тексте/fixture.
- LLM intent не может гарантировать 100% понимание любой фразы, поэтому нужен контролируемый fallback и понятный ответ `не уверен`.
- OpenRouter live-вызовы не должны печатать ключ и не должны считать деньги.

## Не меняется

- DOCX patch/export логика не переписывается.
- Схема БД не меняется без необходимости.
- Секреты и `.env` не читаются и не логируются.
