require "test_helper"

class AgentResponseComposerTest < ActiveSupport::TestCase
  FORBIDDEN_WORDS = [
    "parser worker",
    "post_export_validation",
    "PROGRAM_TOTAL_DIFF",
    "manual_insert_required",
    "INSERTED_IN_DOCX",
    "ChangeSet",
    "intent",
    "tool_call",
    "metadata",
    "LOCAL_BUDGET",
    "детерминирован"
  ].freeze

  setup do
    @user = create_isolated_user!(email: "agent-response-composer@example.com")
    @organization = @user.organization
  end

  test "composes a human response without forbidden technical words" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "validate_control_sums",
      tool_result: {
        "status" => "completed",
        "items" => [
          { "year" => 2026, "status_label" => "Есть расхождение между текущей программой и внешним источником", "delta_rub" => "-10.00" }
        ]
      }
    ).compose

    assert_equal "assistant", response.fetch("role")
    FORBIDDEN_WORDS.each do |word|
      assert_no_match(/#{Regexp.escape(word)}/i, response.fetch("content"))
    end
    assert_match(/контрольные суммы/i, response.fetch("content"))
    assert_match(/2026/, response.fetch("content"))
  end

  test "scrubs legacy assistant text before rendering" do
    content = AgentResponseComposer.scrub_content("ChangeSet manual_insert_required LOCAL_BUDGET intent")

    assert_match(/проект изменений/i, content)
    assert_match(/местный бюджет/i, content)
    FORBIDDEN_WORDS.each do |word|
      assert_no_match(/#{Regexp.escape(word)}/i, content)
    end
  end

  test "scrubs legacy document status machine wording before rendering" do
    content = AgentResponseComposer.scrub_content(
      "Файл есть в рабочем состоянии: Основание.pdf — PDF-основание, статус: Разобран выбран для расчета. Режим сейчас: PDF как частичные правки."
    )

    assert_match(/Вижу в рабочем состоянии/i, content)
    assert_match(/Режим расчета/i, content)
    assert_no_match(/Файл есть в рабочем состоянии|статус:/i, content)
  end

  test "does not keep legacy ready-docx wording without current validation cards" do
    content = AgentResponseComposer.scrub_content(
      "DOCX сформирован. Проект изменений #18 применен, создана версия программы #45. Файлы DOCX и отчет доступны на странице проекта изменений."
    )

    assert_match(/Ранее была попытка сформировать Word-документ/i, content)
    assert_no_match(/DOCX сформирован/i, content)
    assert_no_match(/доступны на странице проекта изменений/i, content)
  end

  test "does not keep legacy invalid-docx wording as final result" do
    content = AgentResponseComposer.scrub_content(
      "DOCX сформирован, но требует проверки контрольных сумм. Проект изменений #111 применен. Файлы DOCX и отчет доступны на странице проекта изменений."
    )

    assert_match(/Актуальные готовые файлы/i, content)
    assert_no_match(/DOCX сформирован/i, content)
  end

  test "does not expose final download cards for invalid export" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "generate_docx",
      tool_result: {
        "status" => "export_failed",
        "change_project_id" => 38,
        "validation_errors" => [
          { "message" => "Паспортная сумма за 2028 не совпадает" }
        ],
        "download_links" => [
          { "label" => "Скачать новую редакцию DOCX", "url" => "/change_sets/38/export_docx" }
        ]
      }
    ).compose

    assert_match(/не прошел проверку/i, response.fetch("content"))
    assert_empty Array(response.fetch("cards"))
  end

  test "document check response says parsed PDF exists and separates zero extracted changes" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "check_documents",
      tool_result: {
        "status" => "completed",
        "matching_documents" => [
          {
            "id" => 113,
            "type" => "pdf_agreement",
            "kind_label" => "PDF-основание для изменений",
            "filename" => "Соглашение_по_МБТ_субсидии.pdf",
            "status" => "Разобран"
          }
        ],
        "documents" => [],
        "source_mode" => {
          "source_mode_label" => "PDF как частичные правки",
          "calculation_source_document_ids" => [113]
        },
        "latest_analysis_session" => { "change_items_count" => 0 },
        "unsupported_sources" => [
          {
            "source_document_id" => 113,
            "filename" => "Соглашение_по_МБТ_субсидии.pdf",
            "reason" => "PDF не содержит структурированных изменений"
          }
        ]
      }
    ).compose

    assert_match(/Вижу/i, response.fetch("content"))
    assert_match(/Разобран/i, response.fetch("content"))
    assert_match(/не извлек/i, response.fetch("content"))
    assert_no_match(/статус:/i, response.fetch("content"))
    assert_no_match(/не видно|не отображается|загрузить PDF повторно/i, response.fetch("content"))
  end

  test "document overview response lists visible documents without fake missing-file warning" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "check_documents",
      tool_result: {
        "status" => "completed",
        "query" => nil,
        "matching_documents" => [
          {
            "type" => "pdf_procedure",
            "kind_label" => "порядок разработки / нормативная база",
            "filename" => "2. № 2291 от 16.10.2025.pdf",
            "status" => "Разобран"
          },
          {
            "type" => "docx_program",
            "kind_label" => "текущая DOCX-программа",
            "filename" => "changeset-89-version-6.docx",
            "status" => "Утвержденная активная редакция"
          }
        ],
        "documents" => [],
        "source_mode" => {
          "source_mode_label" => "Автоматический выбор источника"
        }
      }
    ).compose

    content = response.fetch("content")
    assert_match(/Вижу/i, content)
    assert_match(/2\. № 2291/i, content)
    assert_match(/changeset-89-version-6\.docx/i, content)
    assert_match(/Утвержденная активная редакция/i, content)
    assert_no_match(/Такого файла|не нашел/i, content)
  end

  test "generated documents response answers approved revisions naturally" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "list_generated_documents",
      tool_result: {
        "status" => "completed",
        "documents" => [
          {
            "change_project_id" => 7,
            "change_set_id" => 7,
            "download_links" => [
              { "label" => "Скачать новую редакцию DOCX", "url" => "/change_sets/7/export_docx" }
            ]
          }
        ]
      }
    ).compose

    assert_match(/вижу утвержденн/i, response.fetch("content"))
    assert_match(/№7/, response.fetch("content"))
    assert_no_match(/Файл есть в рабочем состоянии|статус:/i, response.fetch("content"))
  end

  test "analysis response for Excel target shows structured change map without false blocking" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "run_analysis",
      tool_result: {
        "status" => "completed",
        "change_project_id" => 40,
        "change_items_count" => 102,
        "resolved_count" => 101,
        "excluded_count" => 1,
        "needs_clarification_count" => 0,
        "source_mode_label" => "Excel как целевая модель",
        "change_summary" => {
          "object_amount_updates" => 52,
          "new_objects" => 28,
          "residual_adjustments" => 21,
          "zeroing_updates" => 31
        },
        "items" => [
          {
            "label" => "Строительство ВЗУ со станцией водоочистки",
            "change_type" => "amount_update",
            "category" => "object_amount_update",
            "year" => 2026,
            "source_label" => "местный бюджет",
            "old_amount_rub" => "100.00",
            "new_amount_rub" => "150.00",
            "delta_rub" => "50.00",
            "row_number" => 21,
            "document_type" => "xlsx_finance",
            "hierarchy" => {
              "subprogram" => "Чистая вода",
              "main_activity" => "Основное мероприятие 02",
              "activity" => "Мероприятие 02.01"
            }
          }
        ]
      }
    ).compose

    content = response.fetch("content")
    assert_match(/проект изменений №40/i, content)
    assert_match(/Excel как целевая модель/i, content)
    assert_match(/сопоставлено: 101/i, content)
    assert_match(/строки изменений/i, content)
    assert_match(/строка Excel 21/i, content)
    assert_no_match(/выпускать нельзя|нельзя выпускать|не применяю/i, content)
  end

  test "analysis clarification response surfaces version choice question" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "run_analysis",
      tool_result: {
        "status" => "needs_clarification",
        "clarification_question" => "У нас есть активная версия и проверенный черновик. В какую версию внести изменения: в активную или в черновик?"
      }
    ).compose

    content = response.fetch("content")
    assert_match(/активная версия/i, content)
    assert_match(/черновик/i, content)
    assert_no_match(/Документы вижу/i, content)
  end

  test "manual transfer response lists both recalculation operations" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "recalculate_object",
      tool_result: {
        "status" => "completed",
        "manual_change_status" => "generated_validated",
        "object_name" => "Строительство артезианских скважин",
        "recalculation" => [
          {
            "year" => 2028,
            "source_type" => "regional_budget",
            "old_amount_rub" => "21297070.00",
            "new_amount_rub" => "19297070.00",
            "delta_rub" => "-2000000.00"
          },
          {
            "year" => 2027,
            "source_type" => "regional_budget",
            "old_amount_rub" => "0.00",
            "new_amount_rub" => "2000000.00",
            "delta_rub" => "2000000.00"
          }
        ],
        "checks" => ["документ прошел проверку"]
      }
    ).compose

    content = response.fetch("content")
    assert_match(/2028/, content)
    assert_match(/2027/, content)
    assert_match(/-2 000 000,00 руб/, content)
    assert_match(/\+2 000 000,00 руб/, content)
  end

  test "manual preview response is readable and uses human funding labels" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "recalculate_object",
      tool_result: {
        "status" => "needs_confirmation",
        "manual_change_status" => "needs_confirmation",
        "object_name" => "Строительство водозаборного узла",
        "recalculation" => [
          {
            "year" => 2027,
            "source_type" => "regional_budget",
            "old_amount_rub" => "10898460.00",
            "new_amount_rub" => "0.00",
            "delta_rub" => "-10898460.00"
          },
          {
            "year" => 2028,
            "source_type" => "regional_budget",
            "old_amount_rub" => "10898460.00",
            "new_amount_rub" => "21796920.00",
            "delta_rub" => "10898460.00"
          }
        ],
        "confirmation_question" => "Проверьте предварительный расчет. Если все правильно, напишите: «да, формируй готовый DOCX»."
      }
    ).compose

    content = response.fetch("content")
    assert_match(/\AЯ подготовил предварительный расчет/m, content)
    assert_match(/\n\nИзменения:\n- 2027, Средства бюджета субъекта РФ:/, content)
    assert_match(/\n- 2028, Средства бюджета субъекта РФ:/, content)
    assert_match(/\n\nПроверьте предварительный расчет/m, content)
    assert_no_match(/regional_budget|REGIONAL_BUDGET/, content)
  end

  test "analysis fallback does not ask the user to repeat the same command" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "run_analysis",
      tool_result: { "status" => "skipped" }
    ).compose

    assert_no_match(/Напишите: «проанализируй документы»/, response.fetch("content"))
  end

  test "analysis zero-result response diagnoses unparsed Excel structure" do
    response = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: "run_analysis",
      tool_result: {
        "status" => "completed",
        "change_project_id" => nil,
        "diagnostics" => {
          "source_document_type" => "xlsx_finance",
          "object_groups_count" => 0,
          "program_totals_count" => 0
        }
      }
    ).compose

    content = response.fetch("content")
    assert_match(/ошибка разбора структуры Excel/i, content)
    assert_no_match(/Изменений по суммам не нашел/i, content)
  end
end
