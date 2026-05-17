# Codex Task 02 — переделать технический стенд в рабочее место чат-агента муниципальных программ

## 0. Контекст

Проект уже имеет полезную техническую основу: Rails-приложение, Docker-стек, загрузку документов, базовый parser worker, OpenRouter-настройки, выбор модели, простую сверку DOCX/XLSX и хранение денежных значений через Decimal/BigDecimal.

Но текущий продуктовый сценарий неправильный. Сейчас главный экран выглядит как техническая панель диагностики: блок `ИИ-агент`, кнопка `Объяснить расхождения через OpenRouter`, сырые статусы `PROGRAM_TOTAL_DIFF`, длинная портянка LLM-объяснения и таблицы. Пользователь не должен работать с этим как с debug-панелью. Нужен понятный чат-агент, который видит загруженные документы, использует инструменты, создает проект изменений, требует подтверждения и после этого формирует новую редакцию DOCX.

Главный принцип: LLM не считает деньги и не правит DOCX напрямую. LLM управляет процессом, объясняет, извлекает смысл из документов и вызывает инструменты. Расчеты, сверки, пересчет дерева, ChangeSet и DOCX patch/export выполняются детерминированными сервисами.

---

## 1. Что сохранить

Сохранить и развивать:

- Rails-приложение `rails_app`.
- Python worker `parser_worker`.
- Docker services: `web`, `sidekiq`, `parser_worker`, `postgres`, `redis`.
- Авторизацию и dev-login `admin@example.com / password123`.
- OpenRouter settings и загрузку списка моделей.
- Возможность менять модель, включая текущую тестовую `deepseek/deepseek-v4-pro`.
- Подключение OpenRouter-ключа через внешний secret/env, не через репозиторий.
- ActiveStorage загрузку документов.
- Существующие типы документов: `docx_program`, `xlsx_finance`, `pdf_procedure`, `pdf_agreement`, `other`.
- BigDecimal/Decimal подход к деньгам.
- Базовую сверку паспортных итогов DOCX/XLSX как внутренний инструмент.
- Существующие тесты.

---

## 2. Что исправить в текущей реализации

### 2.1. Dashboard

Файл: `rails_app/app/views/dashboard/index.html.erb`

Сейчас dashboard является техническим экраном. Нужно заменить его на рабочее место агента:

- чат слева;
- контекст агента справа;
- понятные быстрые действия;
- ссылки на документы, проекты изменений, базу знаний, настройки агента.

Убрать с главной страницы кнопку `Объяснить расхождения через OpenRouter`. Это не пользовательский сценарий.

### 2.2. Сырые статусы

Не показывать пользователю `PROGRAM_TOTAL_DIFF`, `PROGRAM_TOTAL_OK`, `UNASSIGNED_RESIDUAL` как основной текст. Нужен человекочитаемый маппинг:

- `PROGRAM_TOTAL_DIFF` → `Есть расхождение между текущей программой и внешним источником`.
- `PROGRAM_TOTAL_OK` → `Суммы сходятся`.
- `UNASSIGNED_RESIDUAL` → `Служебная или нераспределенная строка Excel`.
- `NEEDS_CONFIRMATION` → `Нужно подтверждение пользователя`.
- `POSSIBLE_DOUBLE_COUNT` → `Возможен двойной учет`.
- `DOCX_CONTROL_SUM_DIFF` → `Внутренние суммы DOCX не сходятся`.
- `MANUAL_INSERT_REQUIRED` → `Нужно выбрать место вставки нового объекта`.

Технические статусы можно показывать только в admin/debug режиме.

### 2.3. Название программы

В коде `ReconciliationBuilder#ensure_program_version!` сейчас есть fallback:

```ruby
name: "Развитие жилищно-коммунального хозяйства"
```

Это неправильно. Название активной программы должно извлекаться из DOCX. Если parser не смог извлечь название, UI должен показывать `Название не определено`, а не подставлять выдуманное название.

### 2.4. DOCX parser

Файл: `parser_worker/municipal_agent/docx_parser.py`

Сейчас parser вытаскивает в основном подпрограммы и паспортные суммы. Этого мало.

Нужно извлекать полное дерево:

`программа → подпрограмма → основное мероприятие → мероприятие → результат → объект → строки финансирования`.

Также нужны координаты в DOCX:

- table index;
- row index;
- cell index;
- исходное raw value;
- unit in document: `thousand_rub` / `rub`;
- source type;
- year.

Без координат нельзя безопасно патчить DOCX с сохранением форматирования.

### 2.5. PDF procedure parser

Файл: `parser_worker/municipal_agent/procedure_pdf_parser.py`

Сейчас parser извлекает несколько правил. Для продукта PDF-порядок должен стать постоянной базой знаний организации.

Нужно индексировать:

- полный текст по страницам;
- требования к структуре муниципальной программы;
- требования к паспорту;
- требования к показателям;
- требования к методикам;
- требования к результатам;
- формы перечней мероприятий;
- формы адресных перечней;
- основания внесения изменений;
- порядок согласования;
- сроки;
- правила отчетности.

### 2.6. Agent tools

Файл: `parser_worker/municipal_agent/agent_tools.py`

Ключевые инструменты сейчас возвращают `pending_implementation`:

- `parse_pdf_agreement`
- `build_program_tree`
- `match_finance_to_program`
- `recalculate_budget_tree`
- `create_changeset`
- `apply_changeset`
- `patch_docx`
- `generate_change_report`

Их нужно реализовывать по этапам. На первой итерации можно оставить часть как честные заглушки, но UI не должен делать вид, что полноценное изменение DOCX уже работает.

### 2.7. ChangeSet

Файл: `rails_app/app/controllers/change_sets_controller.rb`

Сейчас ChangeSet можно создать вручную и перевести в `approved/applied` без реального содержимого и пересчета. Это нужно исправить.

ChangeSet должен создаваться только сервисом анализа на основании текущей программы и выбранных документов-оснований.

Нельзя применять ChangeSet без:

- списка `change_items`;
- проверки сопоставления;
- подтверждения пользователя;
- пересчета дерева;
- контрольной сверки.

### 2.8. Multi-tenant безопасность

Все прямые вызовы вида:

```ruby
ChangeSet.find(params[:id])
SourceDocument.find(params[:id])
ProgramVersion.find(params[:id])
```

заменить на поиск через текущую организацию.

Пример:

```ruby
current_organization.source_documents.find(params[:id])
```

Пользователь одной организации не должен открыть документы, ChangeSet или программу другой организации.

---

## 3. Целевой пользовательский сценарий

### 3.1. Первый вход пользователя

Пользователь открывает сервис. Если у организации нет порядка разработки, агент пишет:

> Привет! Начнем с настройки вашего муниципалитета. Сначала загрузите порядок разработки и внесения изменений в муниципальные программы. Я сохраню его в базе знаний и буду использовать при проверке программы.

Пользователь загружает PDF-порядок/постановление. Документ сохраняется как постоянная база знаний организации.

### 3.2. Загрузка текущей программы

Если порядок уже загружен, но нет активной DOCX-программы, агент пишет:

> Порядок разработки уже загружен. Теперь загрузите текущую редакцию муниципальной программы DOCX. Я построю структуру программы и проверю контрольные суммы.

Пользователь загружает DOCX. Система парсит документ, строит дерево программы и сохраняет активную версию.

### 3.3. Загрузка оснований для изменений

Если порядок и программа есть, агент пишет:

> Вижу порядок разработки и активную муниципальную программу. Теперь загрузите Excel-отчет финансистов или PDF-соглашение/письмо с изменениями. После этого я подготовлю проект изменений.

Пользователь загружает один или несколько документов:

- XLSX-отчет финансистов;
- PDF-соглашение;
- PDF-письмо;
- PDF-уведомление;
- другой документ-основание.

### 3.4. Анализ

Пользователь нажимает `Провести анализ документов` или пишет в чат: `Проанализируй изменения`.

Агент:

1. Проверяет наличие порядка разработки.
2. Проверяет наличие активной DOCX-программы.
3. Проверяет наличие выбранных документов-оснований.
4. Вызывает parser tools.
5. Сопоставляет данные внешних источников с программой.
6. Выявляет изменения по объектам, годам и источникам.
7. Выявляет конфликты и неуверенные сопоставления.
8. Создает черновик ChangeSet.
9. Объясняет результат пользователю.

### 3.5. Подтверждение

Пользователь видит ChangeSet:

- объект;
- подпрограмма;
- основное мероприятие;
- мероприятие;
- год;
- источник финансирования;
- старая сумма;
- новая сумма;
- разница;
- основание: строка Excel или страница PDF;
- уверенность сопоставления;
- статус подтверждения.

Пользователь подтверждает весь ChangeSet или отдельные спорные строки.

### 3.6. Применение

После подтверждения:

1. Изменяются leaf-level funding lines.
2. Все суммы пересчитываются снизу вверх.
3. Проверяются вертикальные и горизонтальные контрольные суммы.
4. Формируется новая версия программы.
5. Создается DOCX на основе исходного файла с сохранением форматирования.
6. Создается отчет изменений.

---

## 4. Новый интерфейс

### 4.1. Навигация

Добавить навигацию:

- `Рабочее место`
- `Документы`
- `Муниципальная программа`
- `Проекты изменений`
- `База знаний`
- `Настройка агента`
- `OpenRouter / модели`
- `Администрирование` — только admin

### 4.2. Root page

Сделать:

```ruby
root "agent_workspace#show"
```

Главный экран:

```text
Муниципальный программный агент
Муниципалитет: ... | Активная программа: ... | Модель: ...

[Левая зона]
Чат с агентом
- список сообщений
- поле ввода
- Отправить
- Очистить чат

[Правая зона]
Контекст агента
- Порядок разработки: загружен / не загружен
- Активная программа: файл, период, статус
- Документы изменений: список
- Последний проект изменений: статус
- Готовые выгрузки: ссылки

[Быстрые действия]
- Загрузить порядок
- Загрузить программу
- Добавить документы изменений
- Провести анализ
- Создать проект изменений
- Проверить контрольные суммы
- Сформировать DOCX
```

### 4.3. Чат

Файлы не загружаются в чат. Файлы загружаются в специальных разделах. Но чат должен видеть загруженные документы через `AgentContextBuilder`.

Кнопка `Очистить чат`:

- очищает только сообщения;
- не удаляет документы;
- не удаляет базу знаний;
- не удаляет проекты изменений;
- создает новое приветственное сообщение на основе текущего состояния.

### 4.4. Документы

Страница `/documents` должна иметь разделы:

1. `Порядок разработки / постановление`
   - один активный документ на организацию;
   - можно заменить новой версией;
   - хранится как база знаний.

2. `Текущая редакция муниципальной программы`
   - версии DOCX;
   - кнопка `Сделать активной`.

3. `Документы-основания для изменений`
   - XLSX финансистов;
   - PDF соглашений/писем/уведомлений;
   - можно выбрать для анализа.

4. `Сформированные документы`
   - новая редакция DOCX;
   - отчет изменений.

### 4.5. База знаний

Страница `/knowledge_base`:

- активный порядок;
- извлеченные правила;
- фрагменты по разделам;
- формы приложений;
- поиск по базе знаний.

На первом этапе можно сделать поиск без embeddings через PostgreSQL `ILIKE` или `tsvector`.

### 4.6. Настройка агента

Страница `/agent_settings`.

Поля:

- `Инструкция агента` — textarea.
- `Основная модель` — select из OpenRouter моделей.
- `Быстрая модель` — select.
- `Температура` — default `0.1`.
- `Порог уверенного сопоставления` — default `0.92`.
- `Денежная погрешность, руб.` — default `10.00`.
- `Использовать базу знаний` — default true.
- `Использовать историю чата` — default true.
- `Автоматически применять точные совпадения` — default false.
- `Показывать технические статусы` — default false.

---

## 5. Инструкция агента по умолчанию

Сохранить как default system prompt в `AgentSetting`.

```text
Ты — ИИ-агент по сопровождению муниципальных программ. Ты работаешь внутри веб-приложения и помогаешь пользователю готовить изменения в муниципальную программу на основании загруженных документов.

Главная цель: подготовить корректную новую редакцию муниципальной программы в формате DOCX, сохранив исходное форматирование и обеспечив сходимость контрольных сумм.

Контекст:
- У каждого муниципалитета есть собственный порядок разработки и внесения изменений в муниципальные программы. Этот документ является основой базы знаний организации.
- У пользователя есть текущая редакция муниципальной программы DOCX.
- Изменения приходят из PDF-документов от органов власти, соглашений, уведомлений, писем или из XLSX-отчетов финансистов.
- Программа имеет иерархию: программа → подпрограмма → основное мероприятие → мероприятие → объект → строки финансирования по годам и источникам.
- Суммы должны сходиться снизу вверх: объекты складываются в мероприятие, мероприятия — в основное мероприятие, основные мероприятия — в подпрограмму, подпрограммы — в паспорт программы.

Правила:
1. Никогда не считай деньги самостоятельно как LLM. Для арифметики всегда вызывай инструменты пересчета и сверки.
2. Не редактируй DOCX напрямую. Для правок используй только инструменты ChangeSet и DOCX export.
3. Перед применением изменений всегда показывай пользователю ChangeSet и требуй подтверждения.
4. Если источник изменений неоднозначен, задай уточняющий вопрос.
5. Если Excel и PDF противоречат друг другу, не выбирай источник сам. Покажи конфликт и попроси пользователя выбрать приоритет.
6. Если объект найден с низкой уверенностью сопоставления, не применяй изменение автоматически.
7. Используй порядок разработки из базы знаний для проверки структуры, сроков, обязательных разделов, правил внесения изменений и согласования.
8. Отвечай понятным языком: что загружено, что найдено, что предлагаешь изменить, какие риски и какие действия нужны.
9. Не показывай пользователю сырые технические статусы без расшифровки.
10. Всегда отделяй факты из документов от своих выводов.

Доступные инструменты:
- parse_docx_program
- parse_pdf_procedure
- parse_xlsx_finance_report
- parse_pdf_agreement
- retrieve_knowledge
- build_program_tree
- inspect_program_structure
- match_external_source
- create_changeset
- recalculate_budget_tree
- validate_control_sums
- patch_docx
- generate_change_report
- ask_user_confirmation

Формат ответа:
- кратко скажи, что ты понял;
- перечисли найденные действия или проблемы;
- предложи следующий шаг;
- если нужен выбор пользователя, сформулируй его явно.
```

---

## 6. Новые модели и миграции

### 6.1. AgentSetting

```ruby
create_table :agent_settings do |t|
  t.references :organization, null: false, foreign_key: true
  t.text :system_prompt, null: false
  t.string :primary_model
  t.string :fast_model
  t.decimal :temperature, precision: 3, scale: 2, default: 0.1, null: false
  t.decimal :match_confidence_threshold, precision: 5, scale: 4, default: 0.92, null: false
  t.decimal :money_tolerance_rub, precision: 20, scale: 2, default: 10, null: false
  t.boolean :use_knowledge_base, default: true, null: false
  t.boolean :use_chat_history, default: true, null: false
  t.boolean :auto_apply_exact_matches, default: false, null: false
  t.boolean :show_technical_statuses, default: false, null: false
  t.timestamps
end
```

### 6.2. AgentConversation

```ruby
create_table :agent_conversations do |t|
  t.references :organization, null: false, foreign_key: true
  t.references :user, null: false, foreign_key: true
  t.string :title, default: "Рабочий чат"
  t.string :status, default: "active", null: false
  t.jsonb :context_snapshot, default: {}, null: false
  t.datetime :cleared_at
  t.timestamps
end
```

### 6.3. AgentMessage

```ruby
create_table :agent_messages do |t|
  t.references :agent_conversation, null: false, foreign_key: true
  t.references :user, foreign_key: true
  t.string :role, null: false # user, assistant, system, tool
  t.text :content, null: false
  t.jsonb :metadata, default: {}, null: false
  t.timestamps
end
```

### 6.4. AgentToolCall

```ruby
create_table :agent_tool_calls do |t|
  t.references :agent_conversation, null: false, foreign_key: true
  t.references :agent_message, foreign_key: true
  t.string :tool_name, null: false
  t.jsonb :arguments, default: {}, null: false
  t.jsonb :result, default: {}, null: false
  t.string :status, default: "created", null: false
  t.text :error_message
  t.datetime :started_at
  t.datetime :finished_at
  t.timestamps
end
```

### 6.5. KnowledgeChunk

```ruby
create_table :knowledge_chunks do |t|
  t.references :organization, null: false, foreign_key: true
  t.references :source_document, foreign_key: true
  t.string :chunk_type, default: "text", null: false
  t.text :title
  t.text :content, null: false
  t.integer :page_number
  t.integer :table_index
  t.integer :row_index
  t.jsonb :metadata, default: {}, null: false
  t.timestamps
end
```

### 6.6. AnalysisSession

```ruby
create_table :analysis_sessions do |t|
  t.references :organization, null: false, foreign_key: true
  t.references :user, null: false, foreign_key: true
  t.references :program_version, null: false, foreign_key: true
  t.string :status, default: "draft", null: false
  t.text :goal
  t.jsonb :selected_source_document_ids, default: [], null: false
  t.jsonb :summary, default: {}, null: false
  t.timestamps
end
```

### 6.7. ChangeItem fields

Добавить в `change_items`, если их нет:

```ruby
old_amount_rub decimal(20,2)
new_amount_rub decimal(20,2)
delta_rub decimal(20,2)
year integer
source_type string
source_reference jsonb default {}
confidence decimal(5,4)
requires_user_confirmation boolean default false
user_confirmed boolean default false
explanation text
status string default "draft"
```

---

## 7. Routes

Заменить/добавить:

```ruby
root "agent_workspace#show"

resource :agent_workspace, only: [:show]
resources :agent_messages, only: [:create]
post "/agent/clear_chat", to: "agent_conversations#clear", as: :clear_agent_chat

resource :agent_settings, only: [:show, :update]

resources :source_documents, path: "documents", only: [:index, :show, :create] do
  member do
    post :make_active
  end
end

resources :analysis_sessions, only: [:create, :show] do
  member do
    post :run_analysis
    post :create_change_set
  end
end

resources :change_sets, only: [:index, :show] do
  member do
    post :confirm_item
    post :approve
    post :apply
    post :export_docx
    post :export_report
  end
end

resources :knowledge_chunks, path: "knowledge_base", only: [:index]
```

`/admin/openrouter_settings` оставить.

---

## 8. Services

Создать сервисы:

- `AgentOrchestrator`
- `AgentContextBuilder`
- `AgentPromptBuilder`
- `AgentToolRegistry`
- `KnowledgeIndexer`
- `KnowledgeRetriever`
- `ProgramTreePersister`
- `ExternalSourceMatcher`
- `ChangeSetBuilder`
- `BudgetTreeRecalculator`
- `ControlSumValidator`
- `DocxPatchClient`
- `ChangeReportBuilder`

### 8.1. AgentContextBuilder

Должен возвращать компактный JSON для агента:

```json
{
  "organization": {"id": 1, "name": "..."},
  "procedure": {"loaded": true, "document_id": 10, "status": "parsed", "rule_count": 42},
  "active_program": {"loaded": true, "program_version_id": 5, "name": "...", "period": "2026-2030", "subprogram_count": 8},
  "change_sources": [{"id": 12, "type": "xlsx_finance", "filename": "...", "status": "parsed"}],
  "latest_change_set": {"id": 3, "status": "pending_confirmation", "items_count": 18},
  "agent_settings": {"primary_model": "deepseek/deepseek-v4-pro", "use_knowledge_base": true}
}
```

### 8.2. AgentOrchestrator

На первой итерации можно без полноценного OpenRouter function calling. Достаточно:

1. сохранить user message;
2. построить context;
3. распознать quick action;
4. вызвать нужный service;
5. сформировать ответ;
6. сохранить assistant message.

Потом добавить structured tool calls.

---

## 9. Parser worker — обязательные доработки

### 9.1. DOCX parser output

Новый JSON:

```json
{
  "program": {"name": "...", "period_start_year": 2026, "period_end_year": 2030},
  "nodes": [
    {
      "stable_key": "...",
      "node_type": "object",
      "parent_stable_key": "...",
      "display_number": "2.1.4",
      "code": "02.01",
      "name": "...",
      "normalized_name": "...",
      "execution_period": "2025-2026",
      "source_table_index": 12,
      "source_row_index": 45,
      "metadata": {}
    }
  ],
  "funding_lines": [
    {
      "node_stable_key": "...",
      "year": 2026,
      "source_type": "MOSCOW_OBLAST_BUDGET",
      "amount_rub": "78330390.00",
      "unit_in_document": "thousand_rub",
      "source_table_index": 12,
      "source_row_index": 46,
      "source_cell_index": 5,
      "raw_value": "78 330,39"
    }
  ],
  "passport_totals_by_year": {},
  "internal_validation": []
}
```

### 9.2. XLSX parser

Сохранять:

- все строки;
- тип строки: program/subprogram/main_activity/activity/object/result/residual/unknown;
- parent activity/main activity/subprogram;
- суммы по годам;
- суммы по источникам;
- object groups;
- duplicate groups;
- validation results.

### 9.3. PDF procedure parser

Создавать chunks:

- `procedure_general`
- `program_structure`
- `indicators_and_results`
- `change_procedure`
- `approval_terms`
- `forms`
- `reporting`

### 9.4. PDF agreement parser

Добавить:

```bash
parser_worker/cli.py parse-agreement-pdf --file path.pdf
```

Извлекать:

- реквизиты документа;
- объект;
- мероприятие/подпрограмму, если есть;
- год;
- источник финансирования;
- старую сумму;
- новую сумму;
- действие: add/remove/move/rename;
- страницу и цитату-основание.

Если PDF плохо извлекается обычным parser, использовать LLM только для структурного извлечения. Все суммы после LLM прогонять через Decimal parser и validation.

---

## 10. Matching и ChangeSet

### 10.1. Правила сопоставления

1. Точное совпадение по коду объекта/мероприятия, если есть.
2. Точное совпадение по нормализованному имени и parent activity.
3. Fuzzy match по имени + same subprogram/activity.
4. Сумма — только дополнительный признак, не основной ключ.
5. Если несколько кандидатов — `needs_confirmation`.
6. Если объект есть во внешнем источнике, но нет в DOCX — `new_object`.
7. Если объект есть в DOCX, но нет во внешнем источнике — не удалять автоматически.

### 10.2. ChangeSet statuses

- `draft`
- `pending_confirmation`
- `ready_for_approval`
- `approved`
- `applied`
- `rejected`

### 10.3. Подтверждение

Нельзя применять ChangeSet без подтверждения пользователя.

Автоматически можно пометить как не требующие уточнения только:

- exact code match;
- exact normalized name match;
- fuzzy match >= threshold и без конфликта.

Но общий ChangeSet все равно должен быть подтвержден перед DOCX export.

---

## 11. DOCX patch/export

### 11.1. Главное правило

Не пересоздавать документ с нуля. Использовать исходный DOCX как шаблон.

### 11.2. Стратегия

- Использовать координаты ячеек из parser: table index, row index, cell index.
- Менять только numeric cells, связанные с ChangeSet и пересчитанными агрегатами.
- Сохранять стили, шрифты, таблицы, объединения ячеек.
- Исходный DOCX не трогать.
- Generated DOCX сохранить как attachment у ChangeSet или новой ProgramVersion.

### 11.3. Формат денег

БД хранит суммы в рублях. DOCX обычно показывает суммы в тыс. руб.

Сделать функцию:

```python
format_money_for_docx(amount_rub, source_cell_raw_value, unit="thousand_rub")
```

Она должна:

- перевести рубли в тыс. руб.;
- использовать запятую как decimal separator;
- сохранить количество знаков после запятой по исходной ячейке;
- сохранить стиль пробелов/неразрывных пробелов по исходной ячейке.

---

## 12. Итерационный план

### Итерация 1 — интерфейс и чат

1. Добавить модели `AgentSetting`, `AgentConversation`, `AgentMessage`, `AgentToolCall`.
2. Добавить `AgentWorkspaceController`.
3. Сделать root рабочим местом агента.
4. Сделать чат, отправку сообщений, очистку чата.
5. Сделать context panel.
6. Сделать quick actions.
7. Сделать страницу `Настройка агента`.
8. Убрать кнопку `Объяснить расхождения через OpenRouter` с главной.
9. Убрать сырые технические статусы из основного UI.
10. Исправить fallback названия программы.

### Итерация 2 — документы и база знаний

1. Переделать загрузку документов в отдельную страницу.
2. Разделить документы на порядок, программу, источники изменений и выгрузки.
3. Добавить `KnowledgeChunk`.
4. Индексировать PDF-порядок.
5. Показывать базу знаний.
6. Подключить `KnowledgeRetriever` к агенту.

### Итерация 3 — полное дерево программы

1. Расширить DOCX parser.
2. Сохранять ProgramNode/FundingLine.
3. Расширить XLSX parser.
4. Сохранять ExcelRow/external tree.
5. Добавить internal validation.

### Итерация 4 — анализ и ChangeSet

1. Добавить AnalysisSession.
2. Реализовать matching.
3. Создавать ChangeSet из XLSX/PDF.
4. Показывать ChangeSet.
5. Подтверждать спорные строки.

### Итерация 5 — пересчет и DOCX export

1. Реализовать пересчет дерева снизу вверх.
2. Реализовать patch DOCX.
3. Создавать новую ProgramVersion.
4. Добавить скачивание DOCX.
5. Добавить отчет изменений.

---

## 13. Acceptance criteria

### UI

- Главный экран — чат с агентом, а не технический dashboard.
- Есть понятный context panel.
- Есть отдельная страница документов.
- Есть база знаний.
- Есть настройка агента.
- Есть кнопка очистки чата.
- Нет кнопки `Объяснить расхождения через OpenRouter` как основного действия.
- Нет сырых статусов без расшифровки.

### Агент

- Агент видит загруженный порядок, программу и документы изменений.
- Агент отвечает исходя из текущего контекста.
- Агент использует выбранную модель OpenRouter.
- Агент не считает суммы сам.
- Агент умеет запускать анализ/ChangeSet через tools.

### Документы

- PDF-порядок хранится как постоянная база знаний организации.
- DOCX-программа становится активной версией.
- XLSX/PDF источники изменений можно выбрать для анализа.
- Generated DOCX создается только после подтвержденного ChangeSet.

### Тесты

Добавить тесты:

```text
Rails integration:
- workspace shows chat, context panel and quick actions
- clear chat clears messages but keeps documents
- agent settings saves system prompt and model
- documents page separates procedure/program/change sources
- no cross-organization document access

Parser:
- DOCX parser returns passport totals and full tree nodes
- DOCX parser detects 8 subprograms on sample file
- DOCX parser finds object containing Черусти and its funding lines
- XLSX parser groups duplicates without double count
- procedure parser creates knowledge chunks

ChangeSet:
- ChangeSet generated from source document contains change items
- unconfirmed ChangeSet cannot be applied
- approved ChangeSet recalculates parent totals

DOCX export:
- original DOCX unchanged
- generated DOCX exists
- generated DOCX opens with python-docx
- changed numeric cells updated
```

---

## 14. Проверки перед сдачей

Выполнить:

```bash
docker-compose config --quiet
docker-compose up -d --build
docker-compose exec -T -e RAILS_ENV=test -e DATABASE_URL=postgres://postgres:postgres@postgres:5432/municipal_agent_test web bundle exec rails db:prepare
docker-compose exec -T -e RAILS_ENV=test -e DATABASE_URL=postgres://postgres:postgres@postgres:5432/municipal_agent_test web bundle exec rails test
./.venv/bin/python -m pytest parser_worker
find rails_app -name '*.rb' -print0 | xargs -0 -n 1 ruby -c
./.venv/bin/python -m compileall -q parser_worker/municipal_agent parser_worker/cli.py
```

Browser smoke:

1. Войти `admin@example.com / password123`.
2. Root открывает рабочее место агента.
3. Видно чат.
4. Видно context panel.
5. Видна кнопка `Настройка агента`.
6. Можно сохранить инструкцию агента.
7. Можно очистить чат.
8. Можно перейти в документы.
9. Документы разделены на порядок, программу и источники изменений.
10. Нет console errors.

---

## 15. Запреты

- Не хранить OpenRouter API key в репозитории.
- Не коммитить реальные секреты.
- Не смешивать данные разных организаций.
- Не применять изменения без подтверждения пользователя.
- Не использовать LLM для окончательных расчетов.
- Не пересоздавать DOCX с нуля.
- Не удалять старые версии документов.
- Не показывать пользователю техническую кашу вместо понятного сценария.

---

## 16. Короткий prompt для Codex

Сначала выполни Итерацию 1 из `CODEX_TASK_02_CHAT_AGENT_REFACTOR.md`. Не трогай секреты OpenRouter. Сохрани существующий parser worker и model registry. Переделай root dashboard в рабочее место агента с чатом, context panel, быстрыми действиями и страницей настройки агента. Удали пользовательскую кнопку `Объяснить расхождения через OpenRouter`. Добавь модели чата и настроек агента. Добавь тесты и browser smoke. Деньги не считай через LLM, DOCX не меняй на этой итерации. После завершения обнови WORKLOG.md и README.md.
