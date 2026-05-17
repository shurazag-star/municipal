require "test_helper"

class AgentWorkspaceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @previous_post_export_validator = Rails.application.config.x.post_export_validator
    Rails.application.config.x.post_export_validator = FakeValidPostExportValidator.new
    @user = create_isolated_user!(email: "workspace@example.com")
    @organization = @user.organization
    login_as(@user)
  end

  teardown do
    Rails.application.config.x.post_export_validator = @previous_post_export_validator
  end

  test "root shows chat workspace context and quick actions without debug OpenRouter action or raw statuses" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed",
      parsed_payload: { "rules" => ["Согласование проекта выполняется в течение 5 рабочих дней"] }
    )
    docx = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed",
      parsed_payload: { "program" => { "name" => "Развитие ЖКХ", "period_start_year" => 2026, "period_end_year" => 2030 } }
    )
    xlsx = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: { "program_totals" => { "2026" => "90.00" } }
    )
    program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    program.update!(current_version: version)
    Reconciliation.create!(
      program_version: version,
      source_document: xlsx,
      status: "PROGRAM_TOTAL_DIFF",
      year: 2026,
      word_amount_rub: "100.00",
      external_amount_rub: "90.00",
      delta_rub: "-10.00",
      details: { docx_source_document_id: docx.id }
    )

    get root_path

    assert_response :success
    assert_select "h1", "Муниципальный программный агент"
    assert_select "h2", "Чат с агентом"
    assert_select "h2", "Контекст агента"
    assert_select "form[action='#{agent_messages_path}']"
    assert_select "form[action='#{clear_agent_chat_path}'] button", "Очистить чат"
    assert_select "button", "Провести анализ"
    assert_select "button", "Проверить контрольные суммы"
    assert_select "a[href='#{agent_settings_path}']", "Настройка агента"
    assert_select "body", /Есть расхождение между текущей программой и внешним источником/
    assert_select "body", { text: /PROGRAM_TOTAL_DIFF/, count: 0 }
    assert_select "body", { text: /Объяснить расхождения через OpenRouter/, count: 0 }
  end

  test "posting a chat message saves user and assistant messages" do
    AgentConversation.active_for!(organization: @organization, user: @user)

    assert_difference "AgentMessage.count", 2 do
      post agent_messages_path, params: { content: "Проанализируй изменения" }
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-user", /Проанализируй изменения/
    assert_select ".chat-message-assistant", minimum: 2
    assert_select "body", /Для анализа/
  end

  test "agent answers from workspace context when user asks whether parsed PDF source exists" do
    AgentConversation.active_for!(organization: @organization, user: @user)
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение_по_МБТ_субсидии_с_оттисками_02_09_2025.pdf",
      status: "parsed",
      parsed_payload: { "changes" => [] }
    )

    post agent_messages_path, params: { content: "Соглашение_по_МБТ_субсидии_с_оттисками_02_09_2025.pdf проверь файл есть?" }

    assert_redirected_to root_path
    follow_redirect!
    assistant_content = AgentMessage.order(:created_at, :id).last.content
    assert_equal "check_documents", AgentToolCall.order(:id).last.tool_name
    assert_match(/Вижу/i, assistant_content)
    assert_match(/PDF-основание/i, assistant_content)
    assert_match(/Разобран/i, assistant_content)
    assert_no_match(/не видно|не отображается|загрузить PDF повторно/i, assistant_content)
  end

  test "full workflow request creates a background agent task instead of asking for row confirmations" do
    AgentConversation.active_for!(organization: @organization, user: @user)

    assert_difference "AgentTask.count", 1 do
      assert_enqueued_jobs 1, only: AgentTaskJob do
        post agent_messages_path, params: { content: "проанализируй и сформируй новую редакцию" }
      end
    end

    task = AgentTask.order(:created_at).last
    assert_equal "full_workflow", task.task_type
    assert_equal "queued", task.status
    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /Принял задачу/i
    assert_select ".chat-message-assistant", { text: /подтверд/i, count: 0 }
  end

  test "full workflow with PDF procedure wording keeps Excel target generation intent" do
    AgentConversation.active_for!(organization: @organization, user: @user)

    content = "Используй загруженный Excel как полную целевую финансовую модель, PDF-порядок только как нормативную базу. Проведи анализ, пересчитай бюджет, сформируй новую редакцию DOCX. Если суммы не сходятся, объясни причину."

    assert_difference "AgentTask.count", 1 do
      assert_enqueued_jobs 1, only: AgentTaskJob do
        post agent_messages_path, params: { content: content }
      end
    end

    task = AgentTask.order(:created_at).last
    assert_equal "full_workflow", task.task_type
    assert_equal "generate_docx", task.progress_payload["intent"]
    assert_equal "xlsx_target", task.progress_payload.dig("intent_arguments", "source_mode")
    assert_equal "xlsx_finance", task.progress_payload.dig("intent_arguments", "source_priority")
  end

  test "smalltalk gets a natural assistant response without technical phrasing" do
    AgentConversation.active_for!(organization: @organization, user: @user)

    post agent_messages_path, params: { content: "привет" }

    assert_redirected_to root_path
    follow_redirect!
    assistant_content = AgentMessage.order(:created_at, :id).last.content
    assert_select ".chat-message-user", /привет/
    assert_select ".chat-message-assistant", /Здравствуйте|Привет/
    assert_select ".chat-message-assistant", /муниципальн/i
    assert_no_match(/расчетные инструменты/i, assistant_content)
    assert_no_match(/deterministic|tool|intent|parser/i, assistant_content)
    assert_select "body", { text: /расчетные инструменты/i, count: 0 }
    assert_select "body", { text: /deterministic|tool|intent|parser/i, count: 0 }
  end

  test "workspace uses a transient agent action strip without persistent tool history" do
    conversation = AgentConversation.active_for!(organization: @organization, user: @user)
    user_message = conversation.agent_messages.create!(role: "user", user: @user, content: "Проведи анализ")
    conversation.agent_tool_calls.create!(
      agent_message: user_message,
      tool_name: "run_analysis",
      arguments: {},
      result: { "execution" => { "status" => "completed" } },
      status: "completed",
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago
    )

    get root_path

    assert_response :success
    assert_select "#agent-progress-panel[data-agent-progress]"
    assert_select "#agent-progress-panel .agent-progress-pulse"
    assert_select "#agent-status-text", /Агент работает/
    assert_select ".agent-tool-trace", false
    assert_select "body", { text: /Что я сделал/, count: 0 }
    assert_select "body", { text: /Провести анализ документов — Завершен/, count: 0 }
    assert_select "form.chat-form[data-agent-form][data-agent-action-label='Разбираю запрос и готовлю ответ']"
    assert_select "form[action='#{agent_messages_path}'][data-agent-form][data-agent-action-label='Провожу анализ документов'] button", /Провести анализ/
  end

  test "workspace formats assistant text without markdown emphasis markers" do
    conversation = AgentConversation.active_for!(organization: @organization, user: @user)
    conversation.agent_messages.create!(
      role: "assistant",
      content: "Для анализа не хватает документов:\n- **Порядок разработки**\n- **Документы-основания**\nЗагрузите их, и я подготовлю проект изменений."
    )

    get root_path

    assert_response :success
    assert_select ".chat-message-assistant", /Порядок разработки/
    assert_select ".chat-message-assistant", /Документы-основания/
    assert_select ".chat-message-assistant ul.agent-message-list li", minimum: 2
    assert_select ".chat-message-assistant", { text: /\*\*/, count: 0 }
  end

  test "workspace keeps chat composer visible with attachment controls" do
    get root_path

    assert_response :success
    assert_select "form.chat-form[enctype='multipart/form-data']"
    assert_select ".chat-composer"
    assert_select ".chat-attach-button[title='Прикрепить документ']", text: "+"
    assert_select "input[type='file'][name='attachment'][id='agent_attachment']"
    assert_select "textarea[placeholder='Напишите агенту...']"
    assert_select "select[name='document_type'] option[value='pdf_agreement']", /PDF-основание/
    assert_select "button.chat-send-button[type='submit'][aria-label='Отправить сообщение']", /↑/
  end

  test "workspace submits agent chat without full page navigation and scrolls messages to latest reply" do
    get root_path

    assert_response :success
    assert_includes @response.body, "event.preventDefault()"
    assert_includes @response.body, "fetch(form.action"
    assert_includes @response.body, "appendAgentThinkingIndicator"
    assert_includes @response.body, "resetChatForm(form);"
    assert_includes @response.body, "replaceChatWorkspaceFromResponse"
    assert_includes @response.body, "scrollChatMessagesToBottom"
    assert_includes @response.body, "setupAgentTaskPolling"
    assert_not_includes @response.body, "agent-live-thinking"
  end

  test "posting a chat attachment uploads source document and enqueues parsing" do
    file_path = Rails.root.join("tmp", "chat_attachment_test.pdf")
    File.binwrite(file_path, "%PDF-1.4\n% test\n")
    upload = Rack::Test::UploadedFile.new(file_path, "application/pdf")

    assert_difference "SourceDocument.count", 1 do
      assert_enqueued_jobs 1, only: ParseDocumentJob do
        post agent_messages_path, params: {
          content: "Проверь этот документ",
          document_type: "pdf_agreement",
          attachment: upload
        }
      end
    end

    document = SourceDocument.order(:created_at).last
    assert_equal @organization, document.organization
    assert_equal @user, document.created_by
    assert_equal "pdf_agreement", document.document_type
    assert_equal "chat_attachment_test.pdf", document.filename
    assert_equal "queued", document.status
    assert document.file_attachment.attached?

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-user", /chat_attachment_test.pdf/
  ensure
    File.delete(file_path) if file_path && File.exist?(file_path)
  end

  test "chat attachment rejects unsupported file extensions before enqueueing parser" do
    file_path = Rails.root.join("tmp", "chat_attachment_test.exe")
    File.binwrite(file_path, "not a document")
    upload = Rack::Test::UploadedFile.new(file_path, "application/octet-stream")

    assert_no_difference "SourceDocument.count" do
      assert_no_enqueued_jobs only: ParseDocumentJob do
        post agent_messages_path, params: {
          content: "Проверь этот документ",
          document_type: "pdf_agreement",
          attachment: upload
        }
      end
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".alert", /Неподдерживаемый формат файла/
  ensure
    File.delete(file_path) if file_path && File.exist?(file_path)
  end

  test "workspace renders only user and assistant messages" do
    conversation = AgentConversation.active_for!(organization: @organization, user: @user)
    conversation.agent_messages.create!(role: "user", user: @user, content: "Покажи проект")
    conversation.agent_messages.create!(role: "assistant", content: "Показываю проект изменений.")
    conversation.agent_messages.create!(role: "system", content: "SECRET SYSTEM PROMPT")
    conversation.agent_messages.create!(role: "tool", content: "{\"debug\":\"raw tool payload\"}")

    get root_path

    assert_response :success
    assert_select ".chat-message-user", /Покажи проект/
    assert_select ".chat-message-assistant", /Показываю проект изменений/
    assert_select "body", { text: /SECRET SYSTEM PROMPT/, count: 0 }
    assert_select "body", { text: /raw tool payload/, count: 0 }
  end

  test "workspace sanitizes legacy assistant messages before rendering" do
    conversation = AgentConversation.active_for!(organization: @organization, user: @user)
    conversation.agent_messages.create!(
      role: "assistant",
      content: "ChangeSet готов, manual_insert_required: 2, source LOCAL_BUDGET, intent=generate_docx"
    )

    get root_path

    assert_response :success
    assert_select "body", /проект изменений/i
    assert_select "body", /местный бюджет/i
    assert_select "body", { text: /ChangeSet/, count: 0 }
    assert_select "body", { text: /manual_insert_required/, count: 0 }
    assert_select "body", { text: /LOCAL_BUDGET/, count: 0 }
    assert_select "body", { text: /intent/, count: 0 }
  end

  test "procedure question uses knowledge base and answers from loaded procedure" do
    procedure = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    @organization.knowledge_chunks.create!(
      source_document: procedure,
      chunk_type: "approval_terms",
      title: "Согласование",
      content: "Проект изменений подлежит согласованию с финансовым управлением в течение 5 рабочих дней.",
      page_number: 7
    )

    post agent_messages_path, params: { content: "Нужно ли согласование и какие сроки?" }

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /По загруженному порядку разработки/i
    assert_select ".chat-message-assistant", /5 рабочих дней/
    assert_equal "search_knowledge_base", AgentToolCall.last.tool_name
  end

  test "run analysis quick action creates analysis session and changeset when documents are ready" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed",
      parsed_payload: { "chunks" => [] }
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed",
      parsed_payload: { "program" => { "name" => "Развитие ЖКХ", "period_start_year" => 2026, "period_end_year" => 2030 } }
    )
    program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    program.update!(current_version: version)
    node = version.program_nodes.create!(node_type: "object", name: "ВЗУ Черусти", normalized_name: "взу черусти")
    node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "object_groups" => [
          {
            "group_key" => "01::1000004207.1000005123::ВЗУ Черусти",
            "status" => "GROUPED_OBJECT",
            "funding" => { "2026::LOCAL_BUDGET" => "150.00" },
            "rows" => [
              {
                "row_number" => 61,
                "row_type" => "OBJECT_LEAF_ROW",
                "object_name" => "ВЗУ Черусти",
                "funding" => { "2026::LOCAL_BUDGET" => "150.00" },
                "raw_values" => { "Наименование объекта" => "ВЗУ Черусти" }
              }
            ]
          }
        ]
      }
    )

    assert_difference "AnalysisSession.count", 1 do
      assert_difference "ChangeSet.count", 1 do
        post agent_messages_path, params: { quick_action: "run_analysis" }
      end
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /Анализ выполнен/
    assert_select "body", /проект изменений/i
  end

  test "run analysis resolves safe new object rows instead of asking for manual confirmation" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed",
      parsed_payload: { "chunks" => [] }
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed",
      parsed_payload: { "program" => { "name" => "Развитие ЖКХ", "period_start_year" => 2026, "period_end_year" => 2030 } }
    )
    program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    program.update!(current_version: version)
    subprogram = version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 1",
      normalized_name: "подпрограмма 1",
      display_number: "1"
    )
    version.program_nodes.create!(
      parent: subprogram,
      node_type: "activity",
      code: "02.01",
      display_number: "2.1",
      name: "Мероприятие 02.01",
      normalized_name: "мероприятие 02 01"
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "object_groups" => [
          {
            "group_key" => "101020100000000::NEW-1::Новый объект",
            "status" => "GROUPED_OBJECT",
            "object_name" => "Новый объект",
            "object_code" => "NEW-1",
            "funding" => {
              "2026::LOCAL_BUDGET" => "150.00",
              "2027::LOCAL_BUDGET" => "250.00"
            },
            "rows" => [
              {
                "row_number" => 61,
                "row_type" => "OBJECT_LEAF_ROW",
                "parent_activity_code" => "101020100000000",
                "object_name" => "Новый объект",
                "object_code" => "NEW-1",
                "funding" => {
                  "2026::LOCAL_BUDGET" => "150.00",
                  "2027::LOCAL_BUDGET" => "250.00"
                },
                "raw_values" => { "Наименование объекта" => "Новый объект" }
              }
            ]
          }
        ]
      }
    )

    post agent_messages_path, params: { quick_action: "run_analysis" }

    assert_redirected_to root_path
    follow_redirect!
    assert_equal 2, ChangeSet.last.change_items.where(agent_resolution_status: "resolved").count
    assert_equal 0, ChangeSet.last.change_items.where(agent_resolution_status: "needs_clarification").count
    assert_select "body", /Применимые строки сопоставлены/i
    assert_select "body", { text: /требуют подтверждения/i, count: 0 }
  end

  test "run analysis uses the latest parsed finance document once" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed",
      parsed_payload: { "chunks" => [] }
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed",
      parsed_payload: { "program" => { "name" => "Развитие ЖКХ", "period_start_year" => 2026, "period_end_year" => 2030 } }
    )
    program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    program.update!(current_version: version)
    node = version.program_nodes.create!(node_type: "object", name: "ВЗУ Черусти", normalized_name: "взу черусти")
    node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Старые финансы.xlsx",
      status: "parsed",
      parsed_payload: finance_payload("120.00")
    )
    latest = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Новые финансы.xlsx",
      status: "parsed",
      parsed_payload: finance_payload("150.00")
    )

    post agent_messages_path, params: { quick_action: "run_analysis" }

    assert_equal [latest.id], AnalysisSession.last.selected_source_document_ids
    assert_equal 1, ChangeSet.last.change_items.count
    assert_equal BigDecimal("150.00"), ChangeSet.last.change_items.first.new_amount_rub
  end

  test "run analysis treats PDFs as evidence when Excel target is available by default" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed",
      parsed_payload: { "chunks" => [] }
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed",
      parsed_payload: { "program" => { "name" => "Развитие ЖКХ", "period_start_year" => 2026, "period_end_year" => 2030 } }
    )
    program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    program.update!(current_version: version)
    node = version.program_nodes.create!(node_type: "object", name: "ВЗУ Черусти", normalized_name: "взу черусти")
    node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Старые финансы.xlsx",
      status: "parsed",
      parsed_payload: finance_payload("120.00")
    )
    latest_finance = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Новые финансы.xlsx",
      status: "parsed",
      parsed_payload: finance_payload("150.00")
    )
    pdf_one = pdf_agreement_document!("Соглашение 1.pdf", "160.00")
    pdf_two = pdf_agreement_document!("Соглашение 2.pdf", "170.00")

    post agent_messages_path, params: { quick_action: "run_analysis" }

    selected_ids = AnalysisSession.last.selected_source_document_ids
    assert_equal [latest_finance.id], selected_ids
    assert_equal "xlsx_target_with_pdf_evidence", AnalysisSession.last.summary["source_mode"]
    assert_equal [pdf_one.id, pdf_two.id].sort, AnalysisSession.last.summary["evidence_source_document_ids"].sort
    assert_equal 1, ChangeSet.last.change_items.count
  end

  test "run analysis uses PDF agreements only in pdf patch mode" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed",
      parsed_payload: { "chunks" => [] }
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed",
      parsed_payload: { "program" => { "name" => "Развитие ЖКХ", "period_start_year" => 2026, "period_end_year" => 2030 } }
    )
    program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    program.update!(current_version: version)
    node = version.program_nodes.create!(node_type: "object", name: "ВЗУ Черусти", normalized_name: "взу черусти")
    node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: finance_payload("150.00")
    )
    pdf_one = pdf_agreement_document!("Соглашение 1.pdf", "160.00")
    pdf_two = pdf_agreement_document!("Соглашение 2.pdf", "170.00")
    @organization.update!(settings: @organization.settings.merge("default_source_mode" => "pdf_patch"))

    post agent_messages_path, params: { quick_action: "run_analysis" }

    selected_ids = AnalysisSession.last.selected_source_document_ids
    assert_equal [pdf_one.id, pdf_two.id].sort, selected_ids.sort
    assert_equal "pdf_patch", AnalysisSession.last.summary["source_mode"]
    assert_equal 2, ChangeSet.last.change_items.count
  end

  test "chat confirmation wording runs autonomous resolution and leaves risky rows for clarification" do
    change_set = change_set_with_items!
    safe_item = change_set.change_items.create!(
      program_node: @node,
      change_type: "amount_update",
      status: "needs_confirmation",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "100.00",
      new_amount_rub: "150.00",
      delta_rub: "50.00",
      source_reference: {},
      confidence: "0.95",
      requires_user_confirmation: true,
      user_confirmed: false
    )
    risky_item = change_set.change_items.create!(
      program_node: @node,
      change_type: "amount_update",
      status: "needs_confirmation",
      field_name: "amount_rub",
      year: 2027,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "100.00",
      new_amount_rub: "170.00",
      delta_rub: "70.00",
      source_reference: { "source_conflict" => { "object_name" => "ВЗУ Черусти" } },
      confidence: "0.40",
      requires_user_confirmation: true,
      user_confirmed: false
    )

    post agent_messages_path, params: { content: "подтверди надежные строки" }
    safe_item.reload
    risky_item.reload
    assert safe_item.user_confirmed
    assert_equal "confirmed", safe_item.status
    assert_equal "resolved", safe_item.agent_resolution_status
    assert_not risky_item.user_confirmed
    assert_equal "draft", risky_item.status
    assert_equal "needs_clarification", risky_item.agent_resolution_status
    assert_equal "autonomous_resolution", AgentToolCall.last.tool_name

    post agent_messages_path, params: { content: "подтверди все" }
    assert_not risky_item.reload.user_confirmed
    follow_redirect!
    assert_equal "needs_clarification", risky_item.reload.agent_resolution_status
    assert_select ".chat-message-assistant", /не применяю/i
    assert_not_equal "approved", change_set.reload.status
  end

  test "chat does not approve an empty change project" do
    change_set = change_set_with_items!

    post agent_messages_path, params: { content: "утверди проект изменений" }

    assert_not change_set.reload.approved?
    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /В проекте нет изменений/i
  end

  test "chat shows object level discrepancies for mismatch questions" do
    change_set = change_set_with_items!
    change_set.change_items.create!(
      program_node: @node,
      change_type: "amount_update",
      status: "draft",
      field_name: "amount_rub",
      year: 2028,
      source_type: "MOSCOW_OBLAST_BUDGET",
      old_amount_rub: "690689180.00",
      new_amount_rub: "780689180.00",
      delta_rub: "90000000.00",
      source_reference: {
        "filename" => "Финансы.xlsx",
        "row_number" => 61,
        "object_name" => "ВЗУ Черусти"
      },
      confidence: "0.95"
    )
    finance_document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {}
    )
    Reconciliation.create!(
      program_version: @version,
      source_document: finance_document,
      status: "PROGRAM_TOTAL_DIFF",
      year: 2028,
      word_amount_rub: "690689180.00",
      external_amount_rub: "780689180.00",
      delta_rub: "90000000.00",
      details: {}
    )

    post agent_messages_path, params: { content: "где несовпадения?" }

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /ВЗУ Черусти/
    assert_select ".chat-message-assistant", /2028/
    assert_select ".chat-message-assistant", /Финансы.xlsx/
    assert_equal "validate_control_sums", AgentToolCall.last.tool_name
  end

  test "chat source priority resolves Excel PDF conflict and updates change project" do
    change_set = change_set_with_items!
    xlsx = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {}
    )
    pdf = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    conflict = {
      "object_name" => "ВЗУ Черусти",
      "year" => 2027,
      "source_type" => "LOCAL_BUDGET",
      "sources" => {
        "xlsx_finance" => { "source_document_id" => xlsx.id, "filename" => xlsx.filename, "amount_rub" => "120.00" },
        "pdf_agreement" => { "source_document_id" => pdf.id, "filename" => pdf.filename, "amount_rub" => "150.00" }
      }
    }
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      goal: "Конфликт источников",
      selected_source_document_ids: [xlsx.id, pdf.id],
      status: "completed",
      summary: { "source_conflicts" => [conflict] }
    )
    change_set.update!(analysis_session: session)
    xlsx_item = change_set.change_items.create!(
      program_node: @node,
      change_type: "amount_update",
      status: "needs_confirmation",
      field_name: "amount_rub",
      year: 2027,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "100.00",
      new_amount_rub: "120.00",
      delta_rub: "20.00",
      source_reference: { "source_document_id" => xlsx.id, "document_type" => "xlsx_finance", "source_conflict" => conflict },
      confidence: "0.95",
      requires_user_confirmation: true,
      user_confirmed: false
    )
    pdf_item = change_set.change_items.create!(
      program_node: @node,
      change_type: "amount_update",
      status: "needs_confirmation",
      field_name: "amount_rub",
      year: 2027,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "100.00",
      new_amount_rub: "150.00",
      delta_rub: "50.00",
      source_reference: { "source_document_id" => pdf.id, "document_type" => "pdf_agreement", "source_conflict" => conflict },
      confidence: "0.95",
      requires_user_confirmation: true,
      user_confirmed: false
    )

    post agent_messages_path, params: { content: "используй Excel" }

    assert_equal "rejected", pdf_item.reload.status
    assert_equal "needs_confirmation", xlsx_item.reload.status
    assert_nil xlsx_item.source_reference["source_conflict"]
    assert_equal "xlsx_finance", session.reload.summary.dig("source_resolution", "priority")
    assert_equal "xlsx_target", session.summary.dig("source_resolution", "source_mode")
    assert_equal "xlsx_target", @organization.reload.settings["default_source_mode"]
    check = AgentSelfCheckService.new(change_set: change_set, persist: false, reload_record: false).call
    assert_not_includes check["blocking_reasons"], "есть нерешенные конфликты Excel/PDF"
  end

  test "chat resolves pronoun question from previous object context" do
    change_set = change_set_with_items!
    change_set.change_items.create!(
      program_node: @node,
      change_type: "amount_update",
      status: "draft",
      field_name: "amount_rub",
      year: 2028,
      source_type: "MOSCOW_OBLAST_BUDGET",
      old_amount_rub: "690689180.00",
      new_amount_rub: "780689180.00",
      delta_rub: "90000000.00",
      source_reference: { "page_number" => 3, "evidence_text" => "Увеличить по ВЗУ Черусти." },
      confidence: "0.95"
    )

    post agent_messages_path, params: { content: "что поменялось по Черустям" }
    post agent_messages_path, params: { content: "а почему по нему сумма изменилась?" }

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /ВЗУ Черусти/
    last_call = AgentToolCall.order(:id).last
    assert_equal "explain_object_change", last_call.tool_name
    assert_match(/черуст/i, last_call.arguments.dig("intent_arguments", "object_query").to_s)
  end

  test "chat attachment waits for parsing before running analysis" do
    file_path = Rails.root.join("tmp", "chat_attachment_wait_test.pdf")
    File.binwrite(file_path, "%PDF-1.4\n% test\n")
    upload = Rack::Test::UploadedFile.new(file_path, "application/pdf")

    assert_no_difference "AnalysisSession.count" do
      assert_enqueued_jobs 1, only: ParseDocumentJob do
        post agent_messages_path, params: {
          content: "проанализируй этот документ",
          document_type: "pdf_agreement",
          attachment: upload
        }
      end
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /поставил файл на разбор/i
  ensure
    File.delete(file_path) if file_path && File.exist?(file_path)
  end

  test "generate docx quick action enqueues export and reports artifacts after background job" do
    program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие ЖКХ",
      period_start_year: 2026,
      period_end_year: 2030
    )
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    program.update!(current_version: version)
    source_document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "change_set_source.docx",
      status: "parsed",
      parsed_payload: {}
    )
    source_document.file_attachment.attach(
      io: File.open(Rails.root.join("test/fixtures/files/change_set_source.docx")),
      filename: "change_set_source.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    version.update!(import_summary: { "source_document_id" => source_document.id })
    subprogram = version.program_nodes.create!(node_type: "subprogram", name: "Подпрограмма 1", normalized_name: "подпрограмма 1", display_number: "1")
    parent = version.program_nodes.create!(
      parent: subprogram,
      node_type: "activity",
      code: "02.01",
      display_number: "2.1",
      name: "Мероприятие",
      normalized_name: "мероприятие",
      source_table_index: 0,
      source_row_index: 1
    )
    node = version.program_nodes.create!(
      parent: parent,
      node_type: "object",
      name: "Объект тестовый",
      normalized_name: "объект тестовый",
      display_number: "2.1.1",
      source_table_index: 0,
      source_row_index: 1
    )
    node.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100000.00",
      source_document: source_document,
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 1,
        "source_cell_index" => 4,
        "raw_value" => "100,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    change_set = ChangeSet.create!(
      program_version: version,
      status: "approved",
      summary: "Готовый проект изменений",
      created_by: @user,
      approved_by: @user
    )
    change_set.change_items.create!(
      program_node: node,
      change_type: "amount_update",
      status: "confirmed",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "100000.00",
      new_amount_rub: "150000.00",
      delta_rub: "50000.00",
      source_reference: { "row_number" => 15 },
      confidence: "0.95",
      user_confirmed: true
    )
    change_set.change_items.create!(
      change_type: "new_object",
      status: "confirmed",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Новый объект водоснабжения",
      new_amount_rub: "250000.00",
      delta_rub: "250000.00",
      source_reference: {
        "group_key" => "101020100000000::NEW-1::Новый объект водоснабжения",
        "parent_activity_code" => "101020100000000",
        "object_code" => "NEW-1",
        "object_name" => "Новый объект водоснабжения",
        "row_number" => 77
      },
      confidence: "0.50",
      requires_user_confirmation: false,
      user_confirmed: true
    )

    assert_no_difference "ProgramVersion.count" do
      assert_difference "AgentTask.count", 1 do
        assert_enqueued_jobs 1, only: AgentTaskJob do
          post agent_messages_path, params: { quick_action: "generate_docx" }
        end
      end
    end

    assert_redirected_to root_path
    task = AgentTask.order(:created_at).last
    assert_equal "export", task.task_type
    assert_equal "queued", task.status
    assert_equal "generate_docx", task.progress_payload["intent"]
    assert_equal "approved", change_set.reload.status
    follow_redirect!
    assert_select ".chat-message-assistant", /Принял задачу/i
    assert_select ".chat-message-assistant", { text: /сформировал новую редакцию/i, count: 0 }

    assert_difference "ProgramVersion.count", 1 do
      perform_enqueued_jobs only: AgentTaskJob
    end

    task.reload
    assert_equal "succeeded", task.status
    assert_equal "applied", change_set.reload.status
    assert change_set.generated_docx_attachment.attached?
    assert change_set.change_report_attachment.attached?
    assert_equal 0, change_set.export_summary["manual_insert_required_count"]
    assert_equal 1, change_set.export_summary.dig("docx_patch", "inserted_count")
    get root_path
    assert_response :success
    assert_select ".chat-message-assistant", /сформировал проверенный черновик/i
    assert_select ".chat-message-assistant", /новых объектов вставлено 1/
    assert_select "a", "Скачать новую редакцию DOCX"
    assert_select "a", "Скачать отчет об изменениях"
    assert_select "button", "Сделать актуальной"
  end

  test "generate docx quick action does not fall back to older applied changeset when latest changeset needs confirmation" do
    program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие ЖКХ",
      period_start_year: 2026,
      period_end_year: 2030
    )
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    program.update!(current_version: version)
    older = ChangeSet.create!(
      program_version: version,
      status: "applied",
      summary: "Старый примененный проект",
      created_by: @user,
      approved_by: @user,
      applied_at: 1.hour.ago,
      updated_at: 1.hour.ago
    )
    older.generated_docx_attachment.attach(
      io: StringIO.new("old-docx"),
      filename: "old.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    ChangeSet.create!(
      program_version: version,
      status: "pending_confirmation",
      summary: "Новый неподтвержденный проект",
      created_by: @user,
      updated_at: Time.current
    )

    assert_no_difference "ProgramVersion.count" do
      post agent_messages_path, params: { content: "Сформируй DOCX сейчас" }
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /Принял задачу/i
    assert_equal "export", AgentTask.last.task_type
    assert_select "body", { text: /Старый примененный проект/, count: 0 }
    assert_select "body", { text: /Проект изменений ##{older.id} применен/, count: 0 }
  end

  test "chat explains changes for a free-form object question through a tool call" do
    change_set = change_set_with_items!
    change_set.change_items.create!(
      program_node: @node,
      change_type: "amount_update",
      status: "draft",
      field_name: "amount_rub",
      year: 2028,
      source_type: "MOSCOW_OBLAST_BUDGET",
      old_amount_rub: "690689180.00",
      new_amount_rub: "780689180.00",
      delta_rub: "90000000.00",
      source_reference: { "page_number" => 3, "evidence_text" => "Увеличить по ВЗУ Черусти." },
      confidence: "0.95"
    )

    post agent_messages_path, params: { content: "что поменялось по Черустям" }

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /ВЗУ Черусти/
    assert_select ".chat-message-assistant", /2028/
    assert_select ".chat-message-assistant", /90 000 000/
    assert_includes %w[explain_change explain_object_change], AgentToolCall.last.tool_name
  end

  test "chat shows rows requiring manual review from free-form request" do
    change_set = change_set_with_items!
    change_set.change_items.create!(
      change_type: "new_object",
      status: "needs_confirmation",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Новый объект водоснабжения",
      new_amount_rub: "250000.00",
      delta_rub: "250000.00",
      source_reference: { "page_number" => 5, "evidence_text" => "Новый объект требует подтверждения." },
      confidence: "0.45",
      requires_user_confirmation: true,
      user_confirmed: false,
      agent_resolution_status: "needs_clarification",
      agent_resolution_reason: "Не найден родительский раздел в текущей программе."
    )

    post agent_messages_path, params: { content: "покажи, какие строки требуют ручной проверки" }

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /не применяются без уточнения/i
    assert_select ".chat-message-assistant", /Новый объект водоснабжения/
    assert_equal "show_pending", AgentToolCall.last.tool_name
  end

  test "workspace stylesheet keeps chat scrollable and context text wrapped" do
    AgentConversation.active_for!(organization: @organization, user: @user)

    get root_path

    assert_response :success
    assert_includes @response.body, ".chat-panel"
    assert_includes @response.body, "overflow: visible"
    assert_includes @response.body, ".chat-messages"
    assert_includes @response.body, "height: clamp(360px, 56vh, 680px)"
    assert_includes @response.body, "overflow-y: auto"
    assert_includes @response.body, "overflow-wrap: anywhere"
    assert_includes @response.body, ".context-panel"
  end

  test "clear chat keeps uploaded documents and recreates a welcome message" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed",
      parsed_payload: {}
    )
    conversation = AgentConversation.active_for!(organization: @organization, user: @user)
    user_message = conversation.agent_messages.create!(role: "user", user: @user, content: "Очистить историю")
    assistant_message = conversation.agent_messages.create!(role: "assistant", content: "Принял задачу.")
    conversation.agent_tasks.create!(
      organization: @organization,
      user: @user,
      agent_message: user_message,
      assistant_message: assistant_message,
      status: "succeeded",
      task_type: "full_workflow",
      input_message: "Очистить историю"
    )
    document_count = SourceDocument.where(organization: @organization).count

    post clear_agent_chat_path

    assert_redirected_to root_path
    assert_equal document_count, SourceDocument.where(organization: @organization).count
    conversation.reload
    assert_equal 1, conversation.agent_messages.count
    assert_equal 0, conversation.agent_tasks.count
    assert_equal "assistant", conversation.agent_messages.first.role
    assert_equal({}, conversation.working_state)
    assert_nil conversation.memory_summary.presence
  end

  test "follow-up show list uses last offered unresolved list action" do
    conversation = AgentConversation.active_for!(organization: @organization, user: @user)
    conversation.update!(
      working_state: {
        "last_offered_action" => "show_unresolved_items",
        "last_task" => "autonomous_resolution"
      },
      memory_summary: "Агент предложил показать список строк, которые не удалось разобрать по документам."
    )
    change_set = change_set_with_items!
    change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Новый объект без основания",
      new_amount_rub: "250000.00",
      delta_rub: "250000.00",
      source_reference: { "resolution_blocker" => "не найден родительский раздел" },
      confidence: "0.20",
      agent_resolution_status: "needs_clarification",
      agent_resolution_reason: "Не найден родительский раздел в текущей программе."
    )

    post agent_messages_path, params: { content: "покажи список" }

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".chat-message-assistant", /Новый объект без основания/
    assert_equal "show_pending", AgentToolCall.order(:id).last.tool_name
  end

  test "manual instruction clarification answer continues the same object change" do
    AgentConversation.active_for!(organization: @organization, user: @user)
    program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие ЖКХ",
      period_start_year: 2026,
      period_end_year: 2030
    )
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "uploaded_active")
    program.update!(current_version: version)
    source_docx = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "source.docx",
      status: "parsed",
      parsed_payload: {}
    )
    source_docx.file_attachment.attach(
      io: File.open(Rails.root.join("test/fixtures/files/change_set_source.docx")),
      filename: "source.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    version.update!(import_summary: { "source_document_id" => source_docx.id })
    node = version.program_nodes.create!(
      node_type: "object",
      name: "ВЗУ Черусти",
      normalized_name: "взу черусти",
      source_table_index: 0,
      source_row_index: 1
    )
    node.funding_lines.create!(
      year: 2027,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100000.00",
      source_document: source_docx,
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 1,
        "source_cell_index" => 4,
        "unit_in_document" => "thousand_rub"
      }
    )

    post agent_messages_path, params: { content: "Увеличь объект ВЗУ Черусти на 1 млн в 2027." }

    assert_equal "needs_clarification", ManualChangeInstruction.order(:id).last.clarification_status
    assert_match(/источник/i, AgentMessage.order(:id).last.content)

    post agent_messages_path, params: { content: "местный бюджет" }

    assert_equal "complete", ManualChangeInstruction.order(:id).last.clarification_status
    change_set = ChangeSet.order(:id).last
    assert_equal "applied", change_set.status
    assert_equal "generated_validated", change_set.target_program_version.status
    assert_equal "recalculate_object", AgentToolCall.order(:id).last.tool_name
    assert_equal "manual_instruction", AgentToolCall.order(:id).last.arguments.dig("intent_arguments", "source_mode")
  end

  test "draft version choice answer continues previous manual change" do
    conversation = AgentConversation.active_for!(organization: @organization, user: @user)
    program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие ЖКХ",
      period_start_year: 2026,
      period_end_year: 2030
    )
    source_docx = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "source.docx",
      status: "parsed",
      parsed_payload: {}
    )
    source_docx.file_attachment.attach(
      io: File.open(Rails.root.join("test/fixtures/files/change_set_source.docx")),
      filename: "source.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    active = program.program_versions.create!(
      created_by: @user,
      version_number: 1,
      status: "uploaded_active",
      import_summary: { "source_document_id" => source_docx.id }
    )
    program.update!(current_version: active)
    draft = program.program_versions.create!(
      created_by: @user,
      version_number: 2,
      status: "generated_validated",
      import_summary: { "source_document_id" => source_docx.id, "source_program_version_id" => active.id }
    )
    [active, draft].each do |version|
      node = version.program_nodes.create!(
        node_type: "object",
        name: "ВЗУ Черусти",
        normalized_name: "взу черусти",
        source_table_index: 0,
        source_row_index: 1
      )
      node.funding_lines.create!(
        year: 2027,
        source_type: "LOCAL_BUDGET",
        amount_rub: "100000.00",
        source_document: source_docx,
        metadata: {
          "source_table_index" => 0,
          "source_row_index" => 1,
          "source_cell_index" => 4,
          "unit_in_document" => "thousand_rub"
        }
      )
    end
    existing_draft_change_set = ChangeSet.create!(
      program_version: active,
      target_program_version: draft,
      status: "applied",
      summary: "Проверенный черновик",
      created_by: @user,
      export_summary: {
        "post_export_validation" => { "status" => "valid" },
        "agent_self_check" => { "status" => "passed" },
        "independent_verifier" => { "status" => "passed" },
        "manual_insert_required_count" => 0
      }
    )
    existing_draft_change_set.generated_docx_attachment.attach(
      io: StringIO.new("docx"),
      filename: "draft.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    existing_draft_change_set.change_report_attachment.attach(
      io: StringIO.new("report"),
      filename: "report.html",
      content_type: "text/html"
    )
    conversation.update!(
      working_state: {
        "last_intent" => "recalculate_object",
        "last_arguments" => {
          "object_query" => "ВЗУ Черусти",
          "source_mode" => "manual_instruction",
          "source_type" => "LOCAL_BUDGET",
          "amount_operation" => "increase",
          "delta_rub" => "100000.00",
          "year" => 2027
        },
        "last_assistant_message" => "У нас есть активная версия и проверенный черновик новой редакции. В какую версию внести изменения: в активную или в черновик?"
      }
    )

    post agent_messages_path, params: { content: "черновик" }

    assert_equal "recalculate_object", AgentToolCall.order(:id).last.tool_name
    execution = AgentToolCall.order(:id).last.result["execution"]
    assert_equal "completed", execution["status"]
    assert_equal draft.id, ChangeSet.find(execution["change_set_id"]).program_version_id
  end

  private

  def finance_payload(amount)
    {
      "sheet_name" => "Результат",
      "object_groups" => [
        {
          "group_key" => "01::1000004207.1000005123::ВЗУ Черусти",
          "status" => "GROUPED_OBJECT",
          "funding" => { "2026::LOCAL_BUDGET" => amount },
          "rows" => [
            {
              "row_number" => 61,
              "row_type" => "OBJECT_LEAF_ROW",
              "object_name" => "ВЗУ Черусти",
              "funding" => { "2026::LOCAL_BUDGET" => amount },
              "raw_values" => { "Наименование объекта" => "ВЗУ Черусти" }
            }
          ]
        }
      ]
    }
  end

  def pdf_agreement_document!(filename, amount)
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: filename,
      status: "parsed",
      parsed_payload: {
        "changes" => [
          {
            "object_name" => "ВЗУ Черусти",
            "year" => 2026,
            "source_type" => "LOCAL_BUDGET",
            "amount_rub" => amount
          }
        ]
      }
    )
  end

  def change_set_with_items!
    @program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие ЖКХ",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @program.update!(current_version: @version)
    @node = @version.program_nodes.create!(
      node_type: "object",
      name: "ВЗУ Черусти",
      normalized_name: "взу черусти",
      display_number: "1.1.1"
    )
    ChangeSet.create!(
      program_version: @version,
      status: "pending_confirmation",
      summary: "Тестовый проект изменений",
      created_by: @user
    )
  end

  def login_as(user)
    post session_path, params: { email: user.email, password: "password123" }
  end

  class FakeValidPostExportValidator
    def validate(program_version:, generated_docx_attachment:, generated_docx_bytes:)
      {
        "status" => "valid",
        "errors" => [],
        "warnings" => [],
        "passport" => {},
        "passport_sources" => {},
        "visual_render" => { "status" => "valid" }
      }
    end
  end
end
