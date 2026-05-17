require "test_helper"

class AgentToolRegistryTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "agent-tool-registry@example.com")
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
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: { "object_groups" => [] }
    )
    @session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      selected_source_document_ids: [@source_document.id],
      summary: {
        "source_mode" => "xlsx_target",
        "calculation_source_document_ids" => [@source_document.id]
      }
    )
    @change_set = ChangeSet.create!(
      analysis_session: @session,
      program_version: @version,
      source_document: @source_document,
      status: "draft",
      summary: "Старый проект",
      created_by: @user
    )
    @node = @version.program_nodes.create!(
      node_type: "object",
      name: "ВЗУ Черусти",
      normalized_name: "взу черусти"
    )
  end

  test "does not reuse stale Excel project with duplicate updates for the same object amount" do
    2.times do |index|
      @change_set.change_items.create!(
        program_node: @node,
        change_type: "amount_update",
        status: "confirmed",
        field_name: "amount_rub",
        year: 2026,
        source_type: "LOCAL_BUDGET",
        old_amount_rub: "100.00",
        new_amount_rub: index.zero? ? "150.00" : "175.00",
        delta_rub: index.zero? ? "50.00" : "75.00",
        source_reference: {
          "document_type" => "xlsx_finance",
          "row_number" => index + 10
        },
        confidence: "1.0",
        agent_resolution_status: "resolved"
      )
    end

    registry = AgentToolRegistry.new(organization: @organization, user: @user)
    resolver = SourceModeResolver.new(organization: @organization, requested_mode: "xlsx_target")

    assert_nil registry.send(:reusable_change_project, resolver)
  end

  test "chat recalculation creates checked docx workflow for explicit object amount" do
    previous_validator = Rails.application.config.x.post_export_validator
    begin
      Rails.application.config.x.post_export_validator = FakeValidPostExportValidator.new
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
      @version.update!(import_summary: { "source_document_id" => source_docx.id })
      @node.update!(source_table_index: 0, source_row_index: 1)
      @node.funding_lines.create!(
        year: 2026,
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

      result = AgentToolRegistry.new(organization: @organization, user: @user).execute(
        "recalculate_object",
        context: {
          "active_program" => { "program_version_id" => @version.id },
          "conversation_memory" => { "working_state" => {} }
        },
        arguments: {
          "object_query" => "ВЗУ Черусти",
          "year" => 2026,
          "source_type" => "LOCAL_BUDGET",
          "amount_rub" => "200000.00",
          "amount_operation" => "set"
        }
      )

      assert_equal "completed", result["status"]
      assert_equal "generated_validated", result["manual_change_status"]
      assert_equal "manual_instruction", result["source_mode"]
      assert result["download_links"].present?
      assert_equal @version, @program.reload.current_version
      target_node = ChangeSet.find(result["change_set_id"]).target_program_version.program_nodes.find_by!(name: "ВЗУ Черусти")
      assert_equal BigDecimal("200000.00"), target_node.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
      assert_equal "generated_validated", ChangeSet.find(result["change_set_id"]).target_program_version.status
      assert_equal "complete", ManualChangeInstruction.last.clarification_status
    ensure
      Rails.application.config.x.post_export_validator = previous_validator
    end
  end

  test "chat manual transfer creates two checked operations from text instruction" do
    previous_validator = Rails.application.config.x.post_export_validator
    begin
      Rails.application.config.x.post_export_validator = FakeValidPostExportValidator.new
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
      @version.update!(import_summary: { "source_document_id" => source_docx.id })
      @node.update!(source_table_index: 0, source_row_index: 1)
      @node.funding_lines.create!(
        year: 2026,
        source_type: "REGIONAL_BUDGET",
        amount_rub: "100000.00",
        source_document: source_docx,
        metadata: { "source_table_index" => 0, "source_row_index" => 1, "source_cell_index" => 4, "unit_in_document" => "thousand_rub" }
      )
      @node.funding_lines.create!(
        year: 2028,
        source_type: "REGIONAL_BUDGET",
        amount_rub: "0.00",
        source_document: source_docx,
        metadata: { "source_table_index" => 0, "source_row_index" => 1, "source_cell_index" => 5, "unit_in_document" => "thousand_rub" }
      )

      result = AgentToolRegistry.new(organization: @organization, user: @user).execute(
        "recalculate_object",
        context: {
          "active_program" => { "program_version_id" => @version.id },
          "conversation_memory" => { "working_state" => {} }
        },
        arguments: {
          "_user_content" => "Перенеси 30 000 руб. по областному бюджету с 2026 на 2028 по объекту ВЗУ Черусти.",
          "source_mode" => "manual_instruction"
        }
      )

      assert_equal "completed", result["status"]
      change_set = ChangeSet.find(result["change_set_id"])
      assert_equal 2, change_set.change_items.count
      assert_equal [BigDecimal("-30000.00"), BigDecimal("30000.00")], change_set.change_items.order(:year).map(&:delta_rub)
      assert_equal "manual_instruction", change_set.change_items.first.source_reference["source_mode"]
      assert_equal "transfer", ManualChangeInstruction.last.operation
      assert_equal "complete", ManualChangeInstruction.last.clarification_status
    ensure
      Rails.application.config.x.post_export_validator = previous_validator
    end
  end

  test "employee manual change stops for preview before generating docx" do
    @node.funding_lines.create!(
      year: 2026,
      source_type: "REGIONAL_BUDGET",
      amount_rub: "100000.00"
    )

    result = nil
    assert_difference "ChangeSet.count", 1 do
      result = AgentToolRegistry.new(organization: @organization, user: @user).execute(
        "recalculate_object",
        context: {
          "interface_mode" => "employee",
          "active_program" => { "program_version_id" => @version.id },
          "conversation_memory" => { "working_state" => {} }
        },
        arguments: {
          "_user_content" => "Внеси изменения по объекту ВЗУ Черусти: в подпрограмме 1, основном мероприятии 02, мероприятии 02.01 увеличить областной бюджет на 1000 руб. в 2026 году.",
          "source_mode" => "manual_instruction"
        }
      )
    end

    assert_equal "needs_confirmation", result["status"]
    assert_equal "needs_confirmation", result["manual_change_status"]
    assert_equal "manual_instruction", result["source_mode"]
    assert_equal "ВЗУ Черусти", result["object_name"]
    assert_equal "101000.00", result["recalculation"].first["new_amount_rub"]
    change_set = ChangeSet.find(result["change_set_id"])
    assert_equal "draft", change_set.status
    assert_nil change_set.target_program_version_id
    assert_not change_set.generated_docx_attachment.attached?
  end

  test "chat manual transfer of all funding ignores hierarchy numbers and moves current year amount" do
    previous_validator = Rails.application.config.x.post_export_validator
    begin
      Rails.application.config.x.post_export_validator = FakeValidPostExportValidator.new
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
      @version.update!(import_summary: { "source_document_id" => source_docx.id })
      @node.update!(
        name: "Строительство водозаборного узла в п.Мещерский Бор г.о. Шатура",
        normalized_name: "строительство водозаборного узла в п мещерский бор г о шатура",
        source_table_index: 0,
        source_row_index: 1
      )
      @node.funding_lines.create!(
        year: 2027,
        source_type: "REGIONAL_BUDGET",
        amount_rub: "10898460.00",
        source_document: source_docx,
        metadata: { "source_table_index" => 0, "source_row_index" => 1, "source_cell_index" => 4, "unit_in_document" => "thousand_rub" }
      )
      @node.funding_lines.create!(
        year: 2028,
        source_type: "REGIONAL_BUDGET",
        amount_rub: "10898460.00",
        source_document: source_docx,
        metadata: { "source_table_index" => 0, "source_row_index" => 1, "source_cell_index" => 5, "unit_in_document" => "thousand_rub" }
      )

      result = AgentToolRegistry.new(organization: @organization, user: @user).execute(
        "recalculate_object",
        context: {
          "active_program" => { "program_version_id" => @version.id },
          "conversation_memory" => { "working_state" => {} }
        },
        arguments: {
          "_user_content" => "объект называется «Строительство водозаборного узла в поселке Мещерский Бор городского округа Шатура». Всё финансирование с 2027 года тебе надо перенести на 2028 год. Уточнение пользователя: 10 898,46. Этот объект находится в мероприятии 02.01, основное мероприятие 02, подпрограмма номер 1 «Чистая вода». областной бюджет.",
          "source_mode" => "manual_instruction"
        }
      )

      assert_equal "completed", result["status"]
      change_set = ChangeSet.find(result["change_set_id"])
      assert_equal [BigDecimal("-10898460.00"), BigDecimal("10898460.00")], change_set.change_items.order(:year).map(&:delta_rub)
      assert_equal BigDecimal("0.00"), change_set.target_program_version.program_nodes.find_by!(name: @node.name).funding_lines.find_by!(year: 2027, source_type: "regional_budget").amount_rub
      assert_equal BigDecimal("21796920.00"), change_set.target_program_version.program_nodes.find_by!(name: @node.name).funding_lines.find_by!(year: 2028, source_type: "regional_budget").amount_rub
      assert_equal "full_year_balance", ManualChangeInstruction.last.structured_payload["amount_mode"]
    ensure
      Rails.application.config.x.post_export_validator = previous_validator
    end
  end

  test "manual instruction with missing source asks targeted clarification and does not create change project" do
    before_count = ChangeSet.count

    result = AgentToolRegistry.new(organization: @organization, user: @user).execute(
      "recalculate_object",
      context: {
        "active_program" => { "program_version_id" => @version.id },
        "conversation_memory" => { "working_state" => {} }
      },
      arguments: {
        "_user_content" => "Увеличь объект ВЗУ Черусти на 1 млн в 2027.",
        "source_mode" => "manual_instruction"
      }
    )

    assert_equal "needs_clarification", result["status"]
    assert_match(/источник/i, result["clarification_question"])
    assert_equal before_count, ChangeSet.count
    assert_equal "needs_clarification", ManualChangeInstruction.last.clarification_status
  end

  test "manual change asks active or draft when validated draft is not approved" do
    draft_version = @program.program_versions.create!(created_by: @user, version_number: 2, status: "generated_validated")
    change_set = ChangeSet.create!(
      program_version: @version,
      target_program_version: draft_version,
      status: "applied",
      summary: "Черновик",
      created_by: @user,
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

    result = AgentToolRegistry.new(organization: @organization, user: @user).execute(
      "recalculate_object",
      context: {
        "active_program" => { "program_version_id" => @version.id },
        "conversation_memory" => { "working_state" => {} }
      },
      arguments: {
        "_user_content" => "Увеличь объект ВЗУ Черусти по местному бюджету на 1 млн в 2027.",
        "source_mode" => "manual_instruction"
      }
    )

    assert_equal "needs_clarification", result["status"]
    assert_match(/активную.*черновик/i, result["clarification_question"])
  end

  test "document check uses approved generated docx as active program filename" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "проект изменений МП_май_2026.docx",
      status: "parsed"
    )
    target_version = @program.program_versions.create!(
      created_by: @user,
      version_number: 6,
      status: "approved_active"
    )
    @program.update!(current_version: target_version)
    change_set = ChangeSet.create!(
      program_version: @version,
      target_program_version: target_version,
      status: "applied",
      summary: "Проект изменений применен",
      created_by: @user,
      export_summary: {
        "post_export_validation" => { "status" => "valid" },
        "agent_self_check" => { "status" => "passed" },
        "independent_verifier" => { "status" => "passed" },
        "manual_insert_required_count" => 0
      }
    )
    change_set.generated_docx_attachment.attach(
      io: StringIO.new("docx"),
      filename: "changeset-89-version-6.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    change_set.change_report_attachment.attach(
      io: StringIO.new("report"),
      filename: "report.html",
      content_type: "text/html"
    )
    context = AgentContextBuilder.new(organization: @organization, user: @user).build

    result = AgentToolRegistry.new(organization: @organization, user: @user).execute(
      "check_documents",
      context: context,
      arguments: {}
    )

    active_program = result["documents"].detect { |document| document["role"] == "active_program" }
    assert_equal "changeset-89-version-6.docx", active_program["filename"]
    assert_equal "Утвержденная активная редакция", active_program["status"]
    assert_equal "changeset-89-version-6.docx", context.dig("active_program", "filename")
    assert_not_includes result["documents"].map { |document| document["filename"] }, "проект изменений МП_май_2026.docx"
  end

  test "approve generated version can recover latest valid rejected draft" do
    rejected_version = @program.program_versions.create!(
      created_by: @user,
      version_number: 2,
      status: "generated_rejected"
    )
    change_set = ChangeSet.create!(
      program_version: @version,
      target_program_version: rejected_version,
      status: "rejected",
      summary: "Проверенный проект был отклонен случайно",
      created_by: @user,
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

    result = AgentToolRegistry.new(organization: @organization, user: @user).execute(
      "approve_generated_version",
      context: {},
      arguments: {}
    )

    assert_equal "approved", result["status"]
    assert_equal rejected_version, @program.reload.current_version
    assert_equal "approved_active", rejected_version.reload.status
    assert_equal "applied", change_set.reload.status
  end

  test "clarification can bind unresolved PDF row to selected existing object" do
    @node.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "100000.00")
    change_set = ChangeSet.create!(
      program_version: @version,
      status: "draft",
      summary: "Спорная PDF-строка",
      created_by: @user
    )
    item = change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2027,
      source_type: "LOCAL_BUDGET",
      new_value: "ВЗУ",
      new_amount_rub: nil,
      delta_rub: "1000000.00",
      source_reference: {
        "document_type" => "pdf_agreement",
        "amount_mode" => "delta_plus",
        "delta_rub" => "1000000.00"
      },
      confidence: "0.50",
      agent_resolution_status: "needs_clarification",
      agent_resolution_reason: "Нужно уточнить объект"
    )

    result = AgentToolRegistry.new(organization: @organization, user: @user).execute(
      "confirm_change_items",
      context: {},
      arguments: {
        "change_set_id" => change_set.id,
        "object_query" => "ВЗУ Черусти"
      }
    )

    assert_equal "completed", result["status"]
    assert_equal 1, result["object_resolution_count"]
    item.reload
    assert_equal @node, item.program_node
    assert_equal "amount_update", item.change_type
    assert_equal BigDecimal("100000.00"), item.old_amount_rub
    assert_equal BigDecimal("1100000.00"), item.new_amount_rub
    assert_equal "resolved", item.agent_resolution_status
  end

  class FakeValidPostExportValidator
    def validate(program_version:, generated_docx_attachment:, generated_docx_bytes:)
      {
        "status" => "valid",
        "errors" => [],
        "warnings" => [],
        "passport" => {},
        "passport_sources" => {},
        "object_funding" => { "checked_count" => 0 },
        "aggregate_funding" => { "checked_count" => 0 },
        "visual_render" => { "status" => "valid" }
      }
    end
  end
end
