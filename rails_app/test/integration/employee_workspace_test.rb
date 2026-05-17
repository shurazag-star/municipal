require "test_helper"

class EmployeeWorkspaceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @employee = create_isolated_user!(email: "11@11", password: "1111", role: "user")
    @organization = @employee.organization
  end

  test "employee login opens simplified employee workspace" do
    post session_path, params: { email: "11@11", password: "1111" }

    assert_redirected_to employee_workspace_path
    follow_redirect!
    assert_response :success
    assert_select "h1", "Рабочий кабинет"
    assert_select ".employee-chat-shell"
    assert_select "form.employee-chat-form[action='#{agent_messages_path}']"
    assert_select ".employee-chat-form .chat-attach-button[hidden][aria-hidden='true']", "+"
    assert_select "form[action='#{employee_documents_path}'][enctype='multipart/form-data']", count: 3
    assert_select "form[action='#{employee_documents_path}'][data-loading-form][data-upload-loading-form]", count: 3
    assert_select "label.employee-upload-action[data-loading-target]", count: 3
    assert_select "form[action='#{clear_agent_chat_path}'][data-loading-form][data-loading-label='Очищаю'] button", "Очистить чат"
    assert_select "form[action='#{clear_all_employee_documents_path}'] button", "Удалить все документы"
    assert_select "form[action='#{clear_all_employee_documents_path}'][data-loading-form][data-loading-label='Удаляю']"
    assert_select "input[type='hidden'][name='slot'][value='procedure']"
    assert_select "input[type='hidden'][name='slot'][value='program']"
    assert_select "input[type='hidden'][name='slot'][value='change_source']"
    assert_select "body", /Привет, я твой помощник по внесению изменений в муниципальные программы/
    assert_select "a[href='#{agent_settings_path}']", count: 0
    assert_select "a[href='#{source_documents_path}']", count: 0
    assert_select "a[href='#{admin_openrouter_settings_path}']", count: 0
    assert_select "style", /loading-spinner/
    assert_select "script", /function markFormLoading/
  end

  test "admin root keeps full admin workspace" do
    admin = create_isolated_user!(email: "admin-employee-test@example.com", role: "admin")
    post session_path, params: { email: admin.email, password: "password123" }

    assert_redirected_to root_path
    follow_redirect!
    assert_select "h1", "Муниципальный программный агент"
    assert_select "a[href='#{agent_settings_path}']", "Настройка агента"
  end

  test "employee upload accepts files and queues parsing from simplified slots" do
    post session_path, params: { email: "11@11", password: "1111" }
    follow_redirect!

    file_path = Rails.root.join("tmp", "employee_upload.xlsx")
    File.binwrite(file_path, "test")
    upload = Rack::Test::UploadedFile.new(file_path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")

    assert_difference "SourceDocument.count", 1 do
      assert_enqueued_jobs 1, only: ParseDocumentJob do
        post employee_documents_path, params: { slot: "change_source", file: upload }
      end
    end

    document = SourceDocument.order(:created_at).last
    assert_equal @organization, document.organization
    assert_equal @employee, document.created_by
    assert_equal "xlsx_finance", document.document_type
    assert_equal "queued", document.status
    assert document.file_attachment.attached?
    assert_redirected_to employee_workspace_path
  ensure
    File.delete(file_path) if file_path && File.exist?(file_path)
  end

  test "employee upload rejects unsupported file extensions" do
    post session_path, params: { email: "11@11", password: "1111" }

    file_path = Rails.root.join("tmp", "employee_upload.exe")
    File.binwrite(file_path, "not a document")
    upload = Rack::Test::UploadedFile.new(file_path, "application/octet-stream")

    assert_no_difference "SourceDocument.count" do
      assert_no_enqueued_jobs only: ParseDocumentJob do
        post employee_documents_path, params: { slot: "change_source", file: upload }
      end
    end

    assert_redirected_to employee_workspace_path
    follow_redirect!
    assert_select ".alert", /Неподдерживаемый формат файла/
  ensure
    File.delete(file_path) if file_path && File.exist?(file_path)
  end

  test "employee workspace shows accepted checkmarks without parser internals" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "queued"
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed"
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "pdf_agreement",
      filename: "Основание.pdf",
      status: "failed"
    )
    post session_path, params: { email: "11@11", password: "1111" }
    follow_redirect!

    assert_select ".employee-upload-card.is-accepted", count: 3
    assert_select ".employee-upload-card .employee-checkmark", count: 3
    side_panel_text = css_select(".employee-side-panel").map(&:text).join(" ")
    assert_no_match(/Разобран|Разбирается|Ошибка|failed|queued|parsed/, side_panel_text)
  end

  test "employee workspace keeps chat scroll internal and shows delete controls" do
    procedure = SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed"
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed"
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "xlsx_finance",
      filename: "Основание.xlsx",
      status: "parsed"
    )

    post session_path, params: { email: "11@11", password: "1111" }
    follow_redirect!

    assert_select "style", /employee-chat-shell[^{]*\{[^}]*height: calc\(100vh - 124px\)/m
    assert_select "style", /employee-chat-shell \.chat-messages[^{]*\{[^}]*overflow-y: auto/m
    assert_select "form[action='#{employee_document_path(procedure)}'] input[name='_method'][value='delete']"
    assert_select "form[data-turbo-confirm='Вы уверены, что можно очистить каждое поле?']", minimum: 2
    assert_select "form.employee-delete-form[data-loading-form][data-loading-label='Удаляю']", minimum: 3
    assert_select "form[action='#{clear_current_program_employee_documents_path}'][data-turbo-confirm='Удалить актуальную программу из рабочего кабинета?']"
    assert_select ".employee-delete-button", minimum: 3
  end

  test "employee can clear uploaded slot without opening admin workspace" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "pdf_agreement",
      filename: "Основание.pdf",
      status: "parsed"
    )
    post session_path, params: { email: "11@11", password: "1111" }
    follow_redirect!

    assert_difference "SourceDocument.count", -1 do
      delete employee_document_path(document)
    end

    assert_redirected_to employee_workspace_path
  end

  test "employee can clear current program without deleting other uploaded documents" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed"
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "xlsx_finance",
      filename: "Основание.xlsx",
      status: "parsed"
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed"
    )
    program = MunicipalProgram.create!(organization: @organization, name: "Программа", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @employee, version_number: 1, status: "uploaded_active")
    program.update!(current_version: version)
    session = AnalysisSession.create!(organization: @organization, user: @employee, program_version: version)
    ChangeSet.create!(program_version: version, analysis_session: session, status: "draft", created_by: @employee)

    post session_path, params: { email: "11@11", password: "1111" }
    follow_redirect!

    assert_difference "SourceDocument.where(organization: @organization, document_type: 'docx_program').count", -1 do
      delete clear_current_program_employee_documents_path
    end

    assert_redirected_to employee_workspace_path
    assert_equal 0, @organization.municipal_programs.count
    assert_equal 0, @organization.analysis_sessions.count
    assert_equal 0, ChangeSet.joins(program_version: :municipal_program).where(municipal_programs: { organization_id: @organization.id }).count
    assert_equal 1, @organization.source_documents.where(document_type: "pdf_procedure").count
    assert_equal 1, @organization.source_documents.where(document_type: "xlsx_finance").count
  end

  test "employee can delete all documents and reset chat to a clean workspace" do
    source = SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed"
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "xlsx_finance",
      filename: "Основание.xlsx",
      status: "parsed"
    )
    program = MunicipalProgram.create!(organization: @organization, name: "Программа", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @employee, version_number: 1, status: "uploaded_active")
    program.update!(current_version: version)
    session = AnalysisSession.create!(organization: @organization, user: @employee, program_version: version, selected_source_document_ids: [source.id])
    change_set = ChangeSet.create!(program_version: version, analysis_session: session, status: "draft", created_by: @employee, source_document: source)
    KnowledgeChunk.create!(organization: @organization, source_document: source, content: "Правило")
    ManualChangeInstruction.create!(organization: @organization, user: @employee, change_set: change_set, source_mode: "manual_instruction", operation: "transfer")
    AgentMatchDecision.create!(organization: @organization, user: @employee, analysis_session: session, source_document: source, decision_type: "existing_object", status: "accepted")
    conversation = AgentConversation.active_for!(organization: @organization, user: @employee, audience: "employee")
    conversation.agent_messages.create!(role: "user", user: @employee, content: "Старый запрос")

    post session_path, params: { email: "11@11", password: "1111" }
    follow_redirect!

    delete clear_all_employee_documents_path

    assert_redirected_to employee_workspace_path
    assert_equal 0, @organization.source_documents.count
    assert_equal 0, @organization.municipal_programs.count
    assert_equal 0, @organization.analysis_sessions.count
    assert_equal 0, @organization.knowledge_chunks.count
    assert_equal 0, @organization.manual_change_instructions.count
    assert_equal 0, AgentMatchDecision.where(organization: @organization).count
    conversation.reload
    assert_equal 1, conversation.agent_messages.count
    assert_equal "assistant", conversation.agent_messages.first.role

    follow_redirect!
    assert_select ".notice", /Рабочий кабинет очищен/
    assert_select ".employee-upload-card.is-accepted", count: 0
  end

  test "employee workspace shows delete control for approved versions" do
    program = MunicipalProgram.create!(organization: @organization, name: "Программа", period_start_year: 2026, period_end_year: 2030)
    source_version = program.program_versions.create!(created_by: @employee, version_number: 1, status: "uploaded_active")
    target_version = program.program_versions.create!(created_by: @employee, version_number: 2, status: "approved_active")
    program.update!(current_version: target_version)
    change_set = ChangeSet.create!(
      program_version: source_version,
      target_program_version: target_version,
      status: "applied",
      summary: "Проект изменений применен",
      created_by: @employee,
      export_summary: {
        "post_export_validation" => { "status" => "valid" },
        "agent_self_check" => { "status" => "passed" },
        "independent_verifier" => { "status" => "passed" },
        "manual_insert_required_count" => 0
      }
    )
    change_set.generated_docx_attachment.attach(
      io: StringIO.new("docx"),
      filename: "generated.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    change_set.change_report_attachment.attach(
      io: StringIO.new("report"),
      filename: "report.html",
      content_type: "text/html"
    )

    post session_path, params: { email: "11@11", password: "1111" }
    follow_redirect!

    assert_select ".employee-history-item", /Редакция №2/
    assert_select "form[action='#{change_set_path(change_set)}'] input[name='_method'][value='delete']"
    assert_select "form[data-turbo-confirm='Удалить эту утвержденную редакцию из списка?'][data-loading-form][data-loading-label='Удаляю']"
    assert_select "form[action='#{approve_generated_change_set_path(change_set)}'][data-loading-form][data-loading-label='Активирую'] button", /Сделать актуальн/

    assert_difference "ChangeSet.count", -1 do
      delete change_set_path(change_set)
    end
    assert_redirected_to employee_workspace_path
  end

  test "employee approval stays in workspace and current slot shows generated docx" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @employee,
      document_type: "docx_program",
      filename: "проект март.docx",
      status: "parsed"
    )
    program = MunicipalProgram.create!(organization: @organization, name: "Программа", period_start_year: 2026, period_end_year: 2030)
    source_version = program.program_versions.create!(created_by: @employee, version_number: 1, status: "uploaded_active")
    draft_version = program.program_versions.create!(created_by: @employee, version_number: 2, status: "generated_validated")
    program.update!(current_version: source_version)
    change_set = ChangeSet.create!(
      program_version: source_version,
      target_program_version: draft_version,
      status: "applied",
      summary: "Проект изменений применен",
      created_by: @employee,
      export_summary: {
        "post_export_validation" => { "status" => "valid" },
        "agent_self_check" => { "status" => "passed" },
        "independent_verifier" => { "status" => "passed" },
        "manual_insert_required_count" => 0
      }
    )
    change_set.generated_docx_attachment.attach(
      io: StringIO.new("docx"),
      filename: "generated.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    change_set.change_report_attachment.attach(
      io: StringIO.new("report"),
      filename: "report.html",
      content_type: "text/html"
    )

    post session_path, params: { email: "11@11", password: "1111" }
    follow_redirect!

    post approve_generated_change_set_path(change_set)

    assert_redirected_to employee_workspace_path
    assert_equal draft_version, program.reload.current_version

    follow_redirect!
    assert_select ".notice", /Новая редакция утверждена/
    current_card = css_select(".employee-upload-card").find { |node| node.text.include?("Текущая редакция программы") }
    assert current_card, "current program upload card should be rendered"
    assert_includes current_card.text, "generated.docx"
    assert_select ".employee-history-item", /Редакция №2/
    assert_select "form[action='#{approve_generated_change_set_path(change_set)}'] button", /Сделать актуальн/
  end

  test "employee reject draft asks for corrections without invalidating generated docx" do
    program = MunicipalProgram.create!(organization: @organization, name: "Программа", period_start_year: 2026, period_end_year: 2030)
    source_version = program.program_versions.create!(created_by: @employee, version_number: 1, status: "uploaded_active")
    draft_version = program.program_versions.create!(created_by: @employee, version_number: 2, status: "generated_validated")
    program.update!(current_version: source_version)
    change_set = ChangeSet.create!(
      program_version: source_version,
      target_program_version: draft_version,
      status: "applied",
      summary: "Проект изменений применен",
      created_by: @employee,
      export_summary: {
        "post_export_validation" => { "status" => "valid" },
        "agent_self_check" => { "status" => "passed" },
        "independent_verifier" => { "status" => "passed" },
        "manual_insert_required_count" => 0
      }
    )
    change_set.generated_docx_attachment.attach(
      io: StringIO.new("docx"),
      filename: "generated.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    change_set.change_report_attachment.attach(
      io: StringIO.new("report"),
      filename: "report.html",
      content_type: "text/html"
    )

    post session_path, params: { email: "11@11", password: "1111" }
    follow_redirect!

    post reject_generated_change_set_path(change_set)

    assert_redirected_to employee_workspace_path
    assert_equal "applied", change_set.reload.status
    assert_equal "generated_validated", draft_version.reload.status
    assert change_set.export_ready?

    conversation = AgentConversation.active_for!(organization: @organization, user: @employee, audience: "employee")
    assert_equal true, conversation.working_state["awaiting_draft_feedback"]
    assert_equal change_set.id, conversation.working_state["last_generated_change_set_id"]
    assert_match(/что именно нужно поправить/i, conversation.agent_messages.order(:created_at, :id).last.content)

    follow_redirect!
    assert_select ".chat-message-assistant", /что именно нужно поправить/i
    assert_select "form[action='#{approve_generated_change_set_path(change_set)}'] button", /Сделать актуальн/
  end

  test "employee can approve a previously rejected valid draft" do
    program = MunicipalProgram.create!(organization: @organization, name: "Программа", period_start_year: 2026, period_end_year: 2030)
    source_version = program.program_versions.create!(created_by: @employee, version_number: 1, status: "uploaded_active")
    rejected_version = program.program_versions.create!(created_by: @employee, version_number: 2, status: "generated_rejected")
    program.update!(current_version: source_version)
    change_set = ChangeSet.create!(
      program_version: source_version,
      target_program_version: rejected_version,
      status: "rejected",
      summary: "Проект изменений применен",
      created_by: @employee,
      export_summary: {
        "post_export_validation" => { "status" => "valid" },
        "agent_self_check" => { "status" => "passed" },
        "independent_verifier" => { "status" => "passed" },
        "manual_insert_required_count" => 0
      }
    )
    change_set.generated_docx_attachment.attach(
      io: StringIO.new("docx"),
      filename: "generated.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    change_set.change_report_attachment.attach(
      io: StringIO.new("report"),
      filename: "report.html",
      content_type: "text/html"
    )

    post session_path, params: { email: "11@11", password: "1111" }
    follow_redirect!

    post approve_generated_change_set_path(change_set)

    assert_redirected_to employee_workspace_path
    assert_equal rejected_version, program.reload.current_version
    assert_equal "approved_active", rejected_version.reload.status
    assert_equal "applied", change_set.reload.status
  end
end
