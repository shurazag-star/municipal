require "test_helper"

class ChangeSetsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_post_export_validator = Rails.application.config.x.post_export_validator
    Rails.application.config.x.post_export_validator = FakeValidPostExportValidator.new
    @user = create_isolated_user!(email: "changeset-ui@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие инженерной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @program.update!(current_version: @version)
    @source_document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "change_set_source.docx",
      status: "parsed",
      parsed_payload: {}
    )
    @source_document.file_attachment.attach(
      io: File.open(Rails.root.join("test/fixtures/files/change_set_source.docx")),
      filename: "change_set_source.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    @version.update!(import_summary: { "source_document_id" => @source_document.id })
    @parent = @version.program_nodes.create!(node_type: "activity", name: "Мероприятие", normalized_name: "мероприятие")
    @node = @version.program_nodes.create!(parent: @parent, node_type: "object", name: "ВЗУ Черусти", normalized_name: "взу черусти")
    @node.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100.00",
      source_document: @source_document,
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 1,
        "source_cell_index" => 4,
        "raw_value" => "100,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    @session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      selected_source_document_ids: []
    )
    @change_set = ChangeSet.create!(
      analysis_session: @session,
      program_version: @version,
      status: "draft",
      summary: "Тестовый проект изменений",
      created_by: @user
    )
    @item = @change_set.change_items.create!(
      program_node: @node,
      change_type: "amount_update",
      status: "draft",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "100.00",
      new_amount_rub: "150.00",
      delta_rub: "50.00",
      source_reference: { "row_number" => 61 },
      confidence: "0.80",
      requires_user_confirmation: false
    )
    login_as(@user)
  end

  teardown do
    Rails.application.config.x.post_export_validator = @previous_post_export_validator
  end

  test "shows changeset items without row confirmation controls" do
    get change_set_path(@change_set)

    assert_response :success
    assert_select "h1", "Проект изменений"
    assert_select "body", /ВЗУ Черусти/
    assert_select "body", /2026/
    assert_select "body", /50,00/
    assert_select "form[action='#{confirm_item_change_set_path(@change_set)}'] button", { text: "Подтвердить строку", count: 0 }
    assert_select "form[action='#{approve_change_set_path(@change_set)}'] button", { text: "Подтвердить проект", count: 0 }
    assert_select "form[action='#{apply_change_set_path(@change_set)}'] button", "Применить"
  end

  test "applies draft changeset autonomously with downloads" do
    post apply_change_set_path(@change_set)

    assert_redirected_to change_set_path(@change_set)
    assert_equal "applied", @change_set.reload.status
    assert_equal "resolved", @item.reload.agent_resolution_status
    assert @change_set.generated_docx_attachment.attached?
    assert @change_set.change_report_attachment.attached?
    follow_redirect!
    assert_select "body", /Проект изменений применен/
    assert_select "a", "Скачать DOCX"
    assert_select "a", "Скачать отчет"

    get export_docx_change_set_path(@change_set)
    assert_response :success
    assert_equal @change_set.generated_docx_attachment.download.b, @response.body.b
    assert_includes @response.headers["Content-Disposition"], "attachment"
    assert_includes @response.headers["Content-Type"], "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    get export_report_change_set_path(@change_set)
    assert_response :success
    assert_equal @change_set.change_report_attachment.download.b, @response.body.b
    assert_includes @response.headers["Content-Disposition"], "attachment"
  end

  test "changeset table has horizontal scroll and readable column guards" do
    get change_set_path(@change_set)

    assert_response :success
    assert_select ".table-scroll .changes-table"
    assert_includes @response.body, ".changes-table"
    assert_includes @response.body, "min-width: 1320px"
    assert_includes @response.body, ".changes-table .source-col"
    assert_includes @response.body, "white-space: nowrap"
  end

  private

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
