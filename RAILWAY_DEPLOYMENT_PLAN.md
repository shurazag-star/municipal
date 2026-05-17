# План выкладки Municipal AI Agent на Railway

Дата: 2026-05-17

Цель: выложить текущего AI-агента муниципала на Railway так, чтобы рабочий кабинет сотрудника, кабинет администратора, парсеры, фоновые задачи, OpenRouter и сохранение файлов работали стабильно в продакшене.

## 1. Что должно быть на Railway

Нужен один Railway project с окружением `production` и отдельными сервисами:

1. `municipal-web`
   - Rails 8 приложение.
   - Принимает HTTP-трафик.
   - Выполняет `db:prepare` перед стартом.
   - Слушает порт из `PORT`, который выдает Railway.
   - Имеет healthcheck `/up`.

2. `municipal-worker`
   - Тот же Docker image, но отдельная команда запуска Sidekiq.
   - Обрабатывает `ParseDocumentJob`, `AgentTaskJob`, ActiveStorage jobs и другие фоновые задачи.
   - Использует те же ENV, PostgreSQL, Redis и S3 bucket, что web.

3. `PostgreSQL`
   - Основная база Rails.
   - Хранит пользователей, организации, документы, статусы парсинга, проекты изменений, историю чата, audit log.
   - Rails должен получать `DATABASE_URL` через Railway variable reference.

4. `Redis`
   - Очереди Sidekiq и ActionCable.
   - Rails и worker должны получать `REDIS_URL` через Railway variable reference.

5. `Railway Bucket`
   - S3-compatible object storage для ActiveStorage.
   - Нужен для загруженных DOCX/PDF/XLSX/CSV и сгенерированных DOCX/отчетов.
   - Локальный диск контейнера Railway нельзя использовать для постоянных файлов, потому что он не является надежным общим хранилищем между web/worker/deploy.

Volumes в целевой схеме не нужны для пользовательских документов, если используется Railway Bucket. Volume можно оставить только как fallback для временных файлов, но не как основное хранилище ActiveStorage.

## 2. Что нужно подготовить в коде

1. Добавить production Dockerfile:
   - Ruby 3.3.6.
   - Системные зависимости для Rails, PostgreSQL, LibreOffice, Poppler, Tesseract.
   - Python venv для `parser_worker`.
   - Копирование `parser_worker` внутрь image.
   - Запуск Rails на `${PORT:-3000}`.

2. Добавить `.dockerignore`:
   - Не отправлять в build context `.env`, локальную БД/файлы, `storage`, логи, `.venv`, Playwright artifacts, screenshots.
   - Это важно, потому что локальная папка содержит крупное `storage` и реальные рабочие артефакты.

3. Добавить `railway.toml`:
   - Dockerfile build.
   - `preDeployCommand = "bundle exec rails db:prepare"`.
   - общий `startCommand = "bin/railway-start"` для web и worker.
   - `healthcheckPath = "/up"`.
   - restart policy `ON_FAILURE`.

4. Добавить health route `/up`.

5. Переключить ActiveStorage production на S3-compatible service:
   - добавить `aws-sdk-s3`;
   - настроить `config/storage.yml`;
   - использовать ENV `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION`, `S3_ENDPOINT`;
   - включать через `ACTIVE_STORAGE_SERVICE=railway_bucket`.

6. Убрать Railway blocker:
   - production image обязан содержать `/parser_worker`;
   - иначе локально парсеры работают только за счет docker-compose volume, а на Railway упадут.

7. Добавить единый Railway start script:
   - web запускает Rails на `$PORT`;
   - worker запускает Sidekiq;
   - worker дополнительно поднимает легкий `/up` endpoint, чтобы общий Railway healthcheck не валил worker service.

8. Усилить минимальные production-риски перед публичным доступом:
   - запретить сотруднику прямой доступ к админским рабочим экранам;
   - оставить сотруднику только `employee` flow, чат, загрузку документов и утверждение/отклонение сгенерированных редакций;
   - добавить базовую валидацию загружаемых файлов по размеру и расширению.

9. Подготовить production seed:
   - не использовать демо-пароли `password123` и `1111` в production по умолчанию;
   - создать admin/employee через ENV;
   - demo data загружать только при явном `LOAD_DEMO_DATA=true`.

## 3. ENV для Railway

Общие для web и worker:

- `RAILS_ENV=production`
- `RAILS_LOG_TO_STDOUT=true`
- `RAILS_SERVE_STATIC_FILES=true`
- `SECRET_KEY_BASE`
- `DATABASE_URL=${{Postgres.DATABASE_URL}}`
- `REDIS_URL=${{Redis.REDIS_URL}}`
- `ACTIVE_STORAGE_SERVICE=railway_bucket`
- `S3_BUCKET=${{Bucket.BUCKET}}`
- `S3_ACCESS_KEY_ID=${{Bucket.ACCESS_KEY_ID}}`
- `S3_SECRET_ACCESS_KEY=${{Bucket.SECRET_ACCESS_KEY}}`
- `S3_REGION=${{Bucket.REGION}}`
- `S3_ENDPOINT=${{Bucket.ENDPOINT}}`
- `OPENROUTER_API_KEY`
- `OPENROUTER_MODEL_PRIMARY`
- `OPENROUTER_MODEL_FAST`
- `OPENROUTER_SITE_URL`
- `OPENROUTER_APP_NAME`
- `MONEY_TOLERANCE_RUB`
- `ADMIN_EMAIL`
- `ADMIN_PASSWORD`
- `EMPLOYEE_EMAIL`
- `EMPLOYEE_PASSWORD`
- `MAX_UPLOAD_BYTES`
- `SIDEKIQ_CONCURRENCY`
- `FORCE_SSL=true`

После получения Railway public domain нужно обновить:

- `OPENROUTER_SITE_URL=https://<railway-domain>`

## 4. Порядок выкладки

1. Локально:
   - сохранить этот план;
   - внести только нужные production/deploy/security правки;
   - не менять бизнес-логику парсеров и агента без необходимости;
   - прогнать Rails tests;
   - прогнать Python parser tests;
   - собрать Docker image;
   - проверить, что image содержит `/parser_worker`;
   - проверить, что `.env`, `storage`, логи и локальные артефакты не попадут в git/build context.

2. GitHub:
   - инициализировать git, если репозиторий еще не создан локально;
   - проверить remote `https://github.com/shurazag-star/municipal.git`;
   - не пушить секреты, `storage`, `.env`, локальные логи и screenshots;
   - сделать коммит;
   - push в GitHub.

3. Railway:
   - создать или выбрать Railway project;
   - создать Postgres;
   - создать Redis;
   - создать Railway Bucket;
   - создать `municipal-web` из GitHub repo или через `railway up`;
   - создать `municipal-worker` из того же repo/image;
   - задать ENV для обоих сервисов;
   - для web оставить старт из Dockerfile;
   - для worker задать start command `bundle exec sidekiq -c ${SIDEKIQ_CONCURRENCY:-2}`;
   - задеплоить web и worker;
   - дождаться успешного healthcheck `/up`;
   - выполнить `rails db:seed` в production;
   - проверить логи web/worker.

4. Railway smoke tests:
   - открыть `/up` и убедиться в `200`;
   - открыть `/session/new`;
   - войти в admin cabinet;
   - войти в employee cabinet;
   - проверить, что employee не открывает `/agent_settings`, `/documents`, `/programs`, `/change_sets`;
   - загрузить тестовый документ в employee cabinet;
   - убедиться, что job ушел в Sidekiq и документ получил ожидаемый статус;
   - проверить, что файл сохраняется через S3 bucket;
   - отправить простой чат-запрос агенту;
   - проверить логи на `Completed 500`, `PG::`, `NoMethodError`, `NameError`, `Redis`, `S3`, `OpenRouter` ошибки.

## 5. Риски и контрольные точки

Критично проверить перед публичной передачей ссылок:

- `parser_worker` внутри production image, а не только как локальный volume.
- Web и worker используют один PostgreSQL, один Redis и один S3 bucket.
- В Railway нет демо-паролей по умолчанию.
- Сотрудник не может напрямую менять agent settings и админские данные.
- Загруженные файлы ограничены по типам и размеру.
- Railway healthcheck смотрит на endpoint, который реально возвращает `200`.
- В git не попали `.env`, ключи, `storage`, логи, локальные screenshots и временные файлы.
- OpenRouter key установлен как Railway secret variable, а не закоммичен.

## 6. Что не переносится автоматически

- Локальная база PostgreSQL не переносится автоматически.
- Локальная папка `storage` не переносится автоматически.
- Исторические локальные документы и результаты нужны только если отдельно принято решение о миграции данных.

Для чистого production запуска достаточно seed-пользователей, пустой БД и S3 bucket. Если нужно перенести текущие локальные документы/историю, это отдельный этап миграции с дампом PostgreSQL и переносом ActiveStorage объектов.
