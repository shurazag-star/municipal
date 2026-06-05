require "test_helper"
require "open3"
require "tempfile"

class ChangeSetApplicationServiceTest < ActiveSupport::TestCase
  setup do
    @previous_post_export_validator = Rails.application.config.x.post_export_validator
    Rails.application.config.x.post_export_validator = FakeValidPostExportValidator.new
    @user = create_isolated_user!(email: "changeset-apply@example.com")
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
    @version.update!(
      import_summary: {
        "source_document_id" => @source_document.id,
        "passport_total_cell_coordinates" => {
          "2026" => {
            "table_index" => 0,
            "row_index" => 2,
            "cell_index" => 4,
            "raw_value" => "100,00",
            "unit_in_document" => "thousand_rub"
          },
          "2027" => {
            "table_index" => 0,
            "row_index" => 2,
            "cell_index" => 5,
            "raw_value" => "200,00",
            "unit_in_document" => "thousand_rub"
          }
        }
      }
    )
    @subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 1",
      normalized_name: "подпрограмма 1",
      display_number: "1"
    )
    @parent = @version.program_nodes.create!(
      parent: @subprogram,
      node_type: "activity",
      code: "02.01",
      display_number: "2.1",
      name: "Мероприятие",
      normalized_name: "мероприятие",
      source_table_index: 0,
      source_row_index: 2,
      metadata: {
        "docx_source_cell_index" => 3,
        "docx_source_raw_value" => "Всего",
        "docx_year_cell_indexes" => { "2026" => 4, "2027" => 5 },
        "docx_year_raw_values" => { "2026" => "100,00", "2027" => "200,00" },
        "docx_unit_in_document" => "thousand_rub"
      }
    )
    @object = @version.program_nodes.create!(
      parent: @parent,
      node_type: "object",
      name: "Объект тестовый",
      normalized_name: "объект тестовый",
      display_number: "2.1.1",
      source_table_index: 0,
      source_row_index: 1
    )
    @object.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100000.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 1,
        "source_cell_index" => 4,
        "raw_value" => "100,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    @change_set = ChangeSet.create!(
      program_version: @version,
      status: "approved",
      summary: "Тестовый проект изменений",
      created_by: @user,
      approved_by: @user
    )
    @change_set.change_items.create!(
      program_node: @object,
      change_type: "amount_update",
      status: "confirmed",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "100000.00",
      new_amount_rub: "150000.00",
      delta_rub: "50000.00",
      source_reference: { "row_number" => 10 },
      confidence: "0.95",
      user_confirmed: true
    )
  end

  teardown do
    Rails.application.config.x.post_export_validator = @previous_post_export_validator
  end

  test "refuses to apply a changeset with unresolved risky rows" do
    @change_set.update!(status: "draft", approved_by: nil)
    @change_set.change_items.first.update!(
      source_reference: {
        "source_conflict" => {
          "object_name" => "Объект тестовый",
          "year" => 2026,
          "source_type" => "LOCAL_BUDGET"
        }
      },
      agent_resolution_status: "unresolved"
    )

    assert_raises(ChangeSetApplicationService::ConfirmationRequired) do
      ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!
    end
  end

  test "creates recalculated target version and generated artifacts without changing source docx" do
    original_bytes = @source_document.file_attachment.download

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    @change_set.reload
    assert_equal "applied", @change_set.status
    assert_not_nil @change_set.applied_at
    assert_equal @version, @program.reload.current_version
    assert_equal "generated_validated", @change_set.target_program_version.status
    assert_equal 2, @change_set.target_program_version.version_number
    assert_equal result.target_program_version, @change_set.target_program_version

    target_object = @change_set.target_program_version.program_nodes.find_by!(name: "Объект тестовый")
    target_parent = @change_set.target_program_version.program_nodes.find_by!(name: "Мероприятие")
    assert_equal BigDecimal("150000.00"), target_object.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal BigDecimal("150000.00"), target_parent.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub

    assert @change_set.generated_docx_attachment.attached?
    assert @change_set.change_report_attachment.attached?
    assert_equal original_bytes, @source_document.reload.file_attachment.download
    assert_equal "150,00", generated_docx_cell_text(@change_set.generated_docx_attachment.download, row: 1, col: 4)
    assert_equal "150,00", generated_docx_cell_text(@change_set.generated_docx_attachment.download, row: 2, col: 4)
    report_html = @change_set.change_report_attachment.download.force_encoding("UTF-8")
    assert_includes report_html, "Отчет об изменениях проекта"
    assert_includes report_html, "Средства бюджета муниципального округа Шатура"
    assert_no_match(/ChangeSet|Post-export validation|LOCAL_BUDGET|MANUAL_INSERT_REQUIRED|INSERTED_IN_DOCX/, report_html)
    assert_operator @change_set.export_summary["docx_patch"]["applied_count"].to_i, :>=, 2
    assert_includes %w[valid valid_with_warnings invalid], @change_set.export_summary.dig("post_export_validation", "status")
    assert_equal "passed", @change_set.export_summary.dig("independent_verifier", "status")
    assert_equal 0, @change_set.export_summary["manual_insert_required_count"]
  end

  test "mirrors duplicate finance source rows without double counting them in rollups" do
    @change_set.change_items.destroy_all
    program_root = @version.program_nodes.create!(
      node_type: "program",
      name: "Программа",
      normalized_name: "программа"
    )
    main_source_row = @version.program_nodes.create!(
      parent: program_root,
      node_type: "object",
      name: "Основное мероприятие 01",
      normalized_name: "основное мероприятие 01",
      display_number: "1",
      source_table_index: 5,
      source_row_index: 3,
      metadata: { "source" => "finance_source_row" }
    )
    main_source_row.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100000.00",
      metadata: {
        "source_table_index" => 5,
        "source_row_index" => 5,
        "source_cell_index" => 5,
        "total_cell_index" => 4,
        "unit_in_document" => "thousand_rub"
      }
    )
    main_total_row = @version.program_nodes.create!(
      parent: program_root,
      node_type: "main_activity",
      name: "Основное мероприятие 01",
      normalized_name: "основное мероприятие 01",
      display_number: "1",
      source_table_index: 5,
      source_row_index: 6,
      metadata: {
        "source" => "finance_table",
        "docx_year_cell_indexes" => { "2026" => 5 },
        "docx_total_cell_index" => 4,
        "docx_unit_in_document" => "thousand_rub"
      }
    )
    leaf = @version.program_nodes.create!(
      parent: main_total_row,
      node_type: "object",
      name: "Мероприятие 01.01",
      normalized_name: "мероприятие 01 01",
      display_number: "1.1",
      source_table_index: 5,
      source_row_index: 7,
      metadata: { "source" => "finance_source_row" }
    )
    leaf.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100000.00",
      metadata: {
        "source_table_index" => 5,
        "source_row_index" => 8,
        "source_cell_index" => 5,
        "total_cell_index" => 4,
        "unit_in_document" => "thousand_rub"
      }
    )
    @version.program_nodes.create!(
      parent: main_total_row,
      node_type: "activity",
      name: "Мероприятие 01.01",
      normalized_name: "мероприятие 01 01",
      display_number: "1.1",
      source_table_index: 5,
      source_row_index: 10,
      metadata: {
        "source" => "finance_table",
        "docx_year_cell_indexes" => { "2026" => 5 },
        "docx_total_cell_index" => 4,
        "docx_unit_in_document" => "thousand_rub"
      }
    )
    @version.program_nodes.create!(
      parent: program_root,
      node_type: "object",
      name: "Итого по подпрограмме",
      normalized_name: "итого по подпрограмме",
      display_number: "Итого по подпрограмме",
      source_table_index: 5,
      source_row_index: 14,
      metadata: {
        "source" => "finance_table",
        "docx_summary_row" => true,
        "docx_year_cell_indexes" => { "2026" => 5 },
        "docx_total_cell_index" => 4,
        "docx_unit_in_document" => "thousand_rub"
      }
    )
    @change_set.change_items.create!(
      program_node: leaf,
      change_type: "amount_update",
      status: "confirmed",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "100000.00",
      new_amount_rub: "200000.00",
      delta_rub: "100000.00",
      source_reference: { "row_number" => 12 },
      confidence: "0.95",
      user_confirmed: true
    )
    patch_client = CapturingPatchClient.new

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user, patch_client: patch_client).apply!

    target_version = result.target_program_version
    target_root = target_version.program_nodes.find_by!(name: "Программа")
    target_main_source = target_version.program_nodes.find_by!(name: "Основное мероприятие 01", node_type: "object")
    target_main_total = target_version.program_nodes.find_by!(name: "Основное мероприятие 01", node_type: "main_activity")
    target_activity_total = target_version.program_nodes.find_by!(name: "Мероприятие 01.01", node_type: "activity")
    target_subprogram_total = target_version.program_nodes.find_by!(name: "Итого по подпрограмме")

    assert_equal BigDecimal("200000.00"), target_root.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal BigDecimal("200000.00"), target_main_source.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal BigDecimal("200000.00"), target_main_total.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal BigDecimal("200000.00"), target_activity_total.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal BigDecimal("200000.00"), target_subprogram_total.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub

    updates = patch_client.changes.fetch("cell_updates")
    assert updates.any? { |update| update["row_index"] == 5 && BigDecimal(update["amount_rub"]) == BigDecimal("200000.00") }
    assert updates.any? { |update| update["row_index"] == 6 && update["reason"] == "node_total_year" && BigDecimal(update["amount_rub"]) == BigDecimal("200000.00") }
    assert updates.any? { |update| update["row_index"] == 10 && update["reason"] == "node_total_year" && BigDecimal(update["amount_rub"]) == BigDecimal("200000.00") }
    assert updates.any? { |update| update["row_index"] == 14 && update["reason"] == "node_total_year" && BigDecimal(update["amount_rub"]) == BigDecimal("200000.00") }
  end

  test "infers missing target year metadata from adjacent funding years" do
    @object.funding_lines.create!(
      year: 2027,
      source_type: "LOCAL_BUDGET",
      amount_rub: "0.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 1,
        "source_cell_index" => 5,
        "raw_value" => "0,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    @change_set.change_items.create!(
      program_node: @object,
      change_type: "amount_update",
      status: "confirmed",
      field_name: "amount_rub",
      year: 2028,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "0.00",
      new_amount_rub: "300000.00",
      delta_rub: "300000.00",
      source_reference: { "row_number" => 11 },
      confidence: "0.95",
      user_confirmed: true
    )
    patch_client = CapturingPatchClient.new

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user, patch_client: patch_client).apply!

    target_object = result.target_program_version.program_nodes.find_by!(name: "Объект тестовый")
    target_line = target_object.funding_lines.find_by!(year: 2028, source_type: "LOCAL_BUDGET")
    inferred_update = patch_client.changes["cell_updates"].find do |update|
      update["reason"] == "funding_line_year" &&
        update["program_node_id"] == target_object.id &&
        update["row_index"] == 1 &&
        update["cell_index"] == 6
    end

    assert_equal 6, target_line.metadata["source_cell_index"]
    assert_equal BigDecimal("300000.00"), BigDecimal(inferred_update.fetch("amount_rub"))
  end

  test "does not require post export pdf validation before pdf patch export exists" do
    pdf_document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "pdf-patch.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      selected_source_document_ids: [pdf_document.id],
      source_mode: "pdf_patch",
      summary: {
        "source_mode" => "pdf_patch",
        "calculation_source_document_ids" => [pdf_document.id],
        "pdf_patch_ledger" => {
          "status" => "blocked",
          "entries" => [
            {
              "object_name" => "Объект тестовый",
              "year" => 2026,
              "source_type" => "LOCAL_BUDGET"
            }
          ],
          "blocking_reasons" => ["PDF содержит строки, которые не сопоставлены с объектами программы"]
        }
      }
    )
    @change_set.update!(
      analysis_session: session,
      source_document: pdf_document,
      status: "draft",
      approved_by: nil
    )
    @change_set.change_items.first.update!(
      source_reference: {
        "source_document_id" => pdf_document.id,
        "filename" => pdf_document.filename,
        "document_type" => "pdf_agreement",
        "amount_mode" => "absolute",
        "object_name" => "Объект тестовый"
      },
      agent_resolution_status: "unresolved"
    )

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    assert_equal "applied", @change_set.reload.status
    assert_equal "generated_validated", result.target_program_version.status
    assert_equal "passed", @change_set.export_summary.dig("external_patch_validation", "status")
  end

  test "pdf patch preserves unrelated aggregate rows while recalculating changed branch by delta" do
    @parent.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100000.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 2,
        "source_cell_index" => 4,
        "raw_value" => "100,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    unrelated_parent = @version.program_nodes.create!(
      node_type: "main_activity",
      name: "Несвязанное мероприятие с паспортной корректировкой",
      normalized_name: "несвязанное мероприятие с паспортной корректировкой",
      display_number: "9",
      source_table_index: 0,
      source_row_index: 8,
      metadata: {
        "docx_year_cell_indexes" => { "2026" => 4 },
        "docx_year_raw_values" => { "2026" => "500,00" },
        "docx_unit_in_document" => "thousand_rub"
      }
    )
    unrelated_parent.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "500000.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET"
    )
    unrelated_child = @version.program_nodes.create!(
      parent: unrelated_parent,
      node_type: "object",
      name: "Несвязанный объект",
      normalized_name: "несвязанный объект",
      display_number: "9.1",
      source_table_index: 0,
      source_row_index: 9
    )
    unrelated_child.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "200000.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET"
    )
    pdf_document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "partial-patch.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      selected_source_document_ids: [pdf_document.id],
      source_mode: "pdf_patch",
      summary: { "source_mode" => "pdf_patch" }
    )
    @change_set.update!(analysis_session: session, source_document: pdf_document)
    @change_set.change_items.first.update!(
      source_reference: {
        "source_document_id" => pdf_document.id,
        "document_type" => "pdf_agreement",
        "source_mode" => "pdf_patch"
      }
    )

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    target_parent = result.target_program_version.program_nodes.find_by!(name: "Мероприятие")
    target_unrelated = result.target_program_version.program_nodes.find_by!(name: "Несвязанное мероприятие с паспортной корректировкой")

    assert_equal BigDecimal("150000.00"), target_parent.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal BigDecimal("500000.00"), target_unrelated.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
  end

  test "manual partial change updates passport from baseline totals instead of writing only deltas" do
    program_root = @version.program_nodes.create!(
      node_type: "program",
      name: "Муниципальная программа",
      normalized_name: "муниципальная программа",
      metadata: { "source" => "docx_paragraphs", "stable_key" => "program" }
    )
    @subprogram.update!(parent: program_root)
    @source_document.update!(
      parsed_payload: {
        "passport_amounts" => {
          "2026::LOCAL_BUDGET" => "100000.00",
          "2027::LOCAL_BUDGET" => "200000.00"
        },
        "passport_totals_by_year" => {
          "2026" => "100000.00",
          "2027" => "200000.00"
        },
        "passport_source_total_column_amounts" => {
          "LOCAL_BUDGET" => "300000.00"
        },
        "passport_grand_total_column_amount" => "300000.00"
      }
    )
    @version.update!(
      import_summary: @version.import_summary.merge(
        "passport_source_cell_coordinates" => {
          "2026::LOCAL_BUDGET" => {
            "table_index" => 0,
            "row_index" => 10,
            "cell_index" => 4,
            "raw_value" => "100,00",
            "unit_in_document" => "thousand_rub"
          },
          "2027::LOCAL_BUDGET" => {
            "table_index" => 0,
            "row_index" => 10,
            "cell_index" => 5,
            "raw_value" => "200,00",
            "unit_in_document" => "thousand_rub"
          }
        },
        "passport_source_total_cell_coordinates" => {
          "LOCAL_BUDGET" => {
            "table_index" => 0,
            "row_index" => 10,
            "cell_index" => 3,
            "raw_value" => "300,00",
            "unit_in_document" => "thousand_rub"
          }
        },
        "passport_total_cell_coordinates" => {
          "2026" => {
            "table_index" => 0,
            "row_index" => 11,
            "cell_index" => 4,
            "raw_value" => "100,00",
            "unit_in_document" => "thousand_rub"
          },
          "2027" => {
            "table_index" => 0,
            "row_index" => 11,
            "cell_index" => 5,
            "raw_value" => "200,00",
            "unit_in_document" => "thousand_rub"
          }
        },
        "passport_grand_total_cell_coordinate" => {
          "table_index" => 0,
          "row_index" => 11,
          "cell_index" => 3,
          "raw_value" => "300,00",
          "unit_in_document" => "thousand_rub"
        }
      )
    )
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      source_mode: "manual_instruction",
      summary: { "source_mode" => "manual_instruction" }
    )
    @change_set.update!(analysis_session: session)
    @change_set.change_items.first.update!(
      source_reference: {
        "source_mode" => "manual_instruction",
        "document_type" => "manual_instruction"
      }
    )
    patch_client = CapturingPatchClient.new

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user, patch_client: patch_client).apply!

    passport_source_2026 = patch_client.changes["cell_updates"].find { |update| update["reason"] == "passport_source_year" && update["row_index"] == 10 && update["cell_index"] == 4 }
    passport_source_total = patch_client.changes["cell_updates"].find { |update| update["reason"] == "passport_source_total_column" && update["row_index"] == 10 && update["cell_index"] == 3 }
    passport_total_2026 = patch_client.changes["cell_updates"].find { |update| update["reason"] == "passport_total" && update["row_index"] == 11 && update["cell_index"] == 4 }
    passport_grand_total = patch_client.changes["cell_updates"].find { |update| update["reason"] == "passport_grand_total_column" && update["row_index"] == 11 && update["cell_index"] == 3 }

    assert_equal BigDecimal("150000.00"), BigDecimal(passport_source_2026["amount_rub"])
    assert_equal BigDecimal("350000.00"), BigDecimal(passport_source_total["amount_rub"])
    assert_equal BigDecimal("150000.00"), BigDecimal(passport_total_2026["amount_rub"])
    assert_equal BigDecimal("350000.00"), BigDecimal(passport_grand_total["amount_rub"])

    target_root = result.target_program_version.program_nodes.find_by!(node_type: "program")
    assert_equal BigDecimal("150000.00"), target_root.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
  end

  test "manual change on generated version patches previous generated docx instead of original import docx" do
    @object.funding_lines.create!(
      year: 2027,
      source_type: "LOCAL_BUDGET",
      amount_rub: "0.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 1,
        "source_cell_index" => 5,
        "raw_value" => "0,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    @parent.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100000.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 2,
        "source_cell_index" => 4,
        "raw_value" => "100,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    @parent.funding_lines.create!(
      year: 2027,
      source_type: "LOCAL_BUDGET",
      amount_rub: "0.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 2,
        "source_cell_index" => 5,
        "raw_value" => "0,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    unrelated_parent = @version.program_nodes.create!(
      node_type: "activity",
      code: "03.01",
      display_number: "3.1",
      name: "Другое мероприятие",
      normalized_name: "другое мероприятие",
      source_table_index: 0,
      source_row_index: 3,
      metadata: {
        "docx_year_cell_indexes" => { "2026" => 4 },
        "docx_year_raw_values" => { "2026" => "0,00" },
        "docx_unit_in_document" => "thousand_rub"
      }
    )
    unrelated_object = @version.program_nodes.create!(
      parent: unrelated_parent,
      node_type: "object",
      name: "Другой объект",
      normalized_name: "другой объект",
      display_number: "3.1.1",
      source_table_index: 0,
      source_row_index: 3
    )
    unrelated_object.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "0.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 2,
        "source_cell_index" => 4,
        "raw_value" => "0,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    first_result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!
    @change_set.update!(
      export_summary: @change_set.export_summary.merge(
        "docx_row_insertions" => [
          { "table_index" => 0, "insert_after_row_index" => 1, "rows_count" => 2 }
        ]
      )
    )
    GeneratedVersionApprovalService.new(organization: @organization, user: @user).approve_change_set!(@change_set.reload)

    followup = ChangeSet.create!(
      program_version: first_result.target_program_version,
      status: "draft",
      summary: "Ручная правка по уже сформированной редакции",
      created_by: @user
    )
    followup_object = first_result.target_program_version.program_nodes.find_by!(name: "Другой объект")
    followup.change_items.create!(
      program_node: followup_object,
      change_type: "amount_update",
      status: "confirmed",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "0.00",
      new_amount_rub: "200000.00",
      delta_rub: "200000.00",
      source_reference: { "source_mode" => "manual_instruction", "document_type" => "manual_instruction" },
      confidence: "0.95",
      user_confirmed: true
    )
    patch_client = CapturingPatchClient.new

    followup_result = ChangeSetApplicationService.new(change_set: followup, user: @user, patch_client: patch_client).apply!

    assert_equal "changeset_#{@change_set.id}", patch_client.source_label
    shifted_update = patch_client.changes["cell_updates"].find do |update|
      BigDecimal(update["amount_rub"].to_s) == BigDecimal("200000.0")
    end
    assert_equal 5, shifted_update["row_index"]
    target_followup_object = followup_result.target_program_version.program_nodes.find_by!(name: "Другой объект")
    assert_equal BigDecimal("200000.00"), target_followup_object.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
  end

  test "independent verifier prevents final ready status when object names are numeric" do
    @object.update!(name: "7388096.53313196.0134386810.023247950.0")

    ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    @change_set.reload
    assert_equal "needs_manual_review", @change_set.status
    assert_equal "failed", @change_set.export_summary.dig("independent_verifier", "status")
    assert_includes @change_set.export_summary.dig("independent_verifier", "blocking_reasons"), "в дереве программы есть числовые названия объектов"
  end

  test "creates target nodes funding lines and docx rows for confirmed new objects" do
    @change_set.change_items.create!(
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

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    target_node = result.target_program_version.program_nodes.find_by!(name: "Новый объект водоснабжения")
    assert_equal "object", target_node.node_type
    assert_equal "2.1.2", target_node.display_number
    assert_equal "Мероприятие", target_node.parent.name
    assert_equal BigDecimal("250000.00"), target_node.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal 0, result.manual_insert_required_count
    assert_equal 0, @change_set.reload.export_summary["manual_insert_required_count"]
    assert_equal 1, @change_set.export_summary.dig("docx_patch", "inserted_count")

    rows = generated_docx_rows(@change_set.generated_docx_attachment.download)
    assert rows.any? { |row| row[1] == "Новый объект водоснабжения" && row[3] == "Итого" }
    assert rows.any? { |row| row[1] == "Новый объект водоснабжения" && row[3].to_s.downcase.include?("бюджет") && row[4] == "250,00" }
  end

  test "inserts zero regional row for local-only new object when parent table has regional funding" do
    @object.funding_lines.create!(
      year: 2026,
      source_type: "REGIONAL_BUDGET",
      amount_rub: "50000.00",
      source_document: @source_document,
      raw_source_name: "REGIONAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 2,
        "source_cell_index" => 4,
        "raw_value" => "50,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    @change_set.change_items.create!(
      change_type: "new_object",
      status: "confirmed",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Новый локальный объект",
      new_amount_rub: "250000.00",
      delta_rub: "250000.00",
      source_reference: {
        "group_key" => "101020100000000::NEW-LOCAL::Новый локальный объект",
        "parent_activity_code" => "101020100000000",
        "object_code" => "NEW-LOCAL",
        "object_name" => "Новый локальный объект"
      },
      confidence: "0.95",
      requires_user_confirmation: false,
      user_confirmed: true
    )

    ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    assert_equal 3, @change_set.reload.export_summary.dig("docx_patch", "inserted_rows_count")
    rows = generated_docx_rows(@change_set.generated_docx_attachment.download)
    new_rows = rows.select { |row| row[1] == "Новый локальный объект" }
    assert_equal ["Итого", "Средства бюджета субъекта РФ", "Средства бюджета муниципального округа Шатура"], new_rows.map { |row| row[3] }
    assert_equal "0,00", new_rows.second[4]
    assert_equal "250,00", new_rows.third[4]
  end

  test "keeps generic unassigned residual rows virtual instead of inserting them into docx" do
    @change_set.change_items.create!(
      change_type: "new_object",
      status: "confirmed",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Капитальный ремонт сетей водоснабжения сверх объемов финансирования мероприятия государственной программы Московской области",
      new_amount_rub: "250000.00",
      delta_rub: "250000.00",
      source_reference: {
        "group_key" => "UNASSIGNED_RESIDUAL::101020500000000::112",
        "parent_activity_code" => "101020100000000",
        "object_code" => "0000000000.0000000000",
        "object_name" => "Капитальный ремонт сетей водоснабжения сверх объемов финансирования мероприятия государственной программы Московской области",
        "row_number" => 112
      },
      confidence: "0.50",
      requires_user_confirmation: false,
      user_confirmed: true
    )

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    target_node = result.target_program_version.program_nodes.find_by!(
      name: "Капитальный ремонт сетей водоснабжения сверх объемов финансирования мероприятия государственной программы Московской области"
    )
    assert_equal "residual", target_node.node_type
    assert_equal true, target_node.metadata["docx_virtual_residual"]
    assert_equal "virtual", target_node.metadata["docx_insert_status"]
    assert_equal 0, @change_set.reload.export_summary.dig("docx_patch", "inserted_count")

    target_parent = result.target_program_version.program_nodes.find_by!(name: "Мероприятие")
    assert_equal BigDecimal("400000.00"), target_parent.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
  end

  test "canonicalizes visible municipal residual names before docx insertion" do
    @change_set.change_items.create!(
      change_type: "new_object",
      status: "confirmed",
      field_name: "object",
      year: 2027,
      source_type: "LOCAL_BUDGET",
      new_value: "Строительство и реконструкция объектов водоснабжения",
      new_amount_rub: "34386810.00",
      delta_rub: "34386810.00",
      source_reference: {
        "group_key" => "UNASSIGNED_RESIDUAL::101020100000000::20",
        "parent_activity_code" => "101020100000000",
        "object_code" => "0000000000.0000000000",
        "object_name" => "Строительство и реконструкция объектов водоснабжения",
        "row_number" => 20
      },
      confidence: "0.50",
      requires_user_confirmation: false,
      user_confirmed: true
    )

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    target_node = result.target_program_version.program_nodes.find_by!(
      name: "Строительство и реконструкция объектов водоснабжения муниципальной собственности"
    )
    assert_equal "residual", target_node.node_type
    assert_not target_node.metadata["docx_virtual_residual"]
    assert_equal 1, @change_set.reload.export_summary.dig("docx_patch", "inserted_count")
  end

  test "inserts new object when a funding source has no amount in one of the object years" do
    @object.funding_lines.create!(
      year: 2027,
      source_type: "LOCAL_BUDGET",
      amount_rub: "200000.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 1,
        "source_cell_index" => 5,
        "raw_value" => "200,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    [
      ["LOCAL_BUDGET", 2026, "100000.00"],
      ["REGIONAL_BUDGET", 2027, "200000.00"]
    ].each do |source_type, year, amount|
      @change_set.change_items.create!(
        change_type: "new_object",
        status: "confirmed",
        field_name: "object",
        year: year,
        source_type: source_type,
        new_value: "Новый смешанный объект",
        new_amount_rub: amount,
        delta_rub: amount,
        source_reference: {
          "group_key" => "101020100000000::NEW-MIXED::Новый смешанный объект",
          "parent_activity_code" => "101020100000000",
          "object_code" => "NEW-MIXED",
          "object_name" => "Новый смешанный объект"
        },
        confidence: "0.95",
        requires_user_confirmation: false,
        user_confirmed: true
      )
    end

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    target_node = result.target_program_version.program_nodes.find_by!(name: "Новый смешанный объект")
    assert_equal BigDecimal("100000.00"), target_node.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal BigDecimal("200000.00"), target_node.funding_lines.find_by!(year: 2027, source_type: "REGIONAL_BUDGET").amount_rub
    assert_equal 1, @change_set.reload.export_summary.dig("docx_patch", "inserted_count")
    assert_equal 3, @change_set.export_summary.dig("docx_patch", "inserted_rows_count")
  end

  test "marks invalid export as failed and does not expose it as final" do
    service = ChangeSetApplicationService.new(
      change_set: @change_set,
      user: @user,
      post_export_validator: FakeInvalidPostExportValidator.new
    )

    result = service.apply!

    @change_set.reload
    assert_equal "export_failed", @change_set.status
    assert_equal @version, @program.reload.current_version
    assert @change_set.generated_docx_attachment.attached?
    assert_equal "invalid", @change_set.export_summary.dig("post_export_validation", "status")
    assert_equal result.change_set, @change_set
  end

  test "local budget label uses organization municipality name instead of hard-coded Shatura" do
    @organization.update!(name: "Городской округ Тестовый", municipality_name: "городского округа Тестовый")
    @change_set.change_items.create!(
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
        "object_name" => "Новый объект водоснабжения"
      },
      confidence: "0.95",
      user_confirmed: true
    )

    ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    rows = generated_docx_rows(@change_set.generated_docx_attachment.download)
    local_budget_rows = rows.flatten.compact.select { |cell| cell.include?("Средства бюджета") }
    assert local_budget_rows.any? { |cell| cell.include?("городского округа Тестовый") }
    assert local_budget_rows.none? { |cell| cell.include?("Шатура") }
  end

  test "assigns sequential display numbers and generated row coordinates for multiple new objects under one parent" do
    ["Новый объект 1", "Новый объект 2"].each_with_index do |name, index|
      @change_set.change_items.create!(
        change_type: "new_object",
        status: "confirmed",
        field_name: "object",
        year: 2026,
        source_type: "LOCAL_BUDGET",
        new_value: name,
        new_amount_rub: "#{250000 + index}.00",
        delta_rub: "#{250000 + index}.00",
        source_reference: {
          "group_key" => "101020100000000::NEW-#{index}::#{name}",
          "parent_activity_code" => "101020100000000",
          "object_code" => "NEW-#{index}",
          "object_name" => name,
          "row_number" => 80 + index
        },
        confidence: "0.50",
        requires_user_confirmation: false,
        user_confirmed: true
      )
    end

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    first = result.target_program_version.program_nodes.find_by!(name: "Новый объект 1")
    second = result.target_program_version.program_nodes.find_by!(name: "Новый объект 2")
    assert_equal "2.1.2", first.display_number
    assert_equal "2.1.3", second.display_number
    assert first.source_row_index < second.source_row_index
    assert_equal 2, @change_set.reload.export_summary.dig("docx_patch", "inserted_count")
    assert_equal 0, result.manual_insert_required_count
  end

  test "anchors inserted objects after full source row block of last sibling" do
    @object.update!(source_row_index: 3)
    @object.funding_lines.create!(
      year: 2027,
      source_type: "REGIONAL_BUDGET",
      amount_rub: "200000.00",
      source_document: @source_document,
      raw_source_name: "REGIONAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 5,
        "source_cell_index" => 5,
        "raw_value" => "200,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    new_node = @version.program_nodes.create!(
      parent: @parent,
      node_type: "object",
      name: "Новый объект",
      normalized_name: "новый объект",
      display_number: "2.1.2",
      source_table_index: @parent.source_table_index
    )

    anchor = ChangeSetApplicationService.new(change_set: @change_set, user: @user).send(:docx_insert_anchor, @parent, new_node)

    assert_equal 5, anchor["insert_after_row_index"]
    assert_equal 3, anchor["template_row_index"]
  end

  test "does not use non numeric summary rows as insertion templates" do
    summary = @version.program_nodes.create!(
      parent: @parent,
      node_type: "object",
      name: "Итого по подпрограмме",
      normalized_name: "итого по подпрограмме",
      display_number: "Итого по подпрограмме",
      source_table_index: 0,
      source_row_index: 8,
      metadata: { "source" => "finance_table", "docx_row_type" => "object" }
    )
    summary.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "1000.00",
      source_document: @source_document,
      raw_source_name: "LOCAL_BUDGET",
      metadata: {
        "source_table_index" => 0,
        "source_row_index" => 10,
        "source_cell_index" => 4,
        "raw_value" => "1,00",
        "unit_in_document" => "thousand_rub"
      }
    )
    new_node = @version.program_nodes.create!(
      parent: @parent,
      node_type: "object",
      name: "Новый объект",
      normalized_name: "новый объект",
      display_number: "2.1.2",
      source_table_index: @parent.source_table_index
    )

    anchor = ChangeSetApplicationService.new(change_set: @change_set, user: @user).send(:docx_insert_anchor, @parent, new_node)

    assert_equal 1, anchor["insert_after_row_index"]
    assert_equal 1, anchor["template_row_index"]
  end

  test "creates new object under unique activity code fallback when external parent subprogram differs" do
    fallback_subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 5",
      normalized_name: "подпрограмма 5",
      display_number: "5"
    )
    fallback_parent = @version.program_nodes.create!(
      parent: fallback_subprogram,
      node_type: "activity",
      code: "01.02",
      display_number: "1.2",
      name: "Единственное мероприятие 01.02",
      normalized_name: "единственное мероприятие 01.02",
      source_table_index: 0,
      source_row_index: 2,
      metadata: @parent.metadata
    )
    @change_set.change_items.create!(
      change_type: "new_object",
      status: "confirmed",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Неуказанное направление",
      new_amount_rub: "34386810.02",
      delta_rub: "34386810.02",
      source_reference: {
        "group_key" => "UNASSIGNED_RESIDUAL::106010200000000::170",
        "parent_activity_code" => "106010200000000",
        "object_code" => "0000000000.0000000000",
        "object_name" => "Неуказанное направление",
        "row_number" => 170
      },
      confidence: "0.50",
      requires_user_confirmation: false,
      user_confirmed: true
    )

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    target_parent = result.target_program_version.program_nodes.find_by!(name: fallback_parent.name)
    target_node = result.target_program_version.program_nodes.find_by!(name: "Неуказанное направление")
    assert_equal target_parent, target_node.parent
    assert_equal "residual", target_node.node_type
    assert_equal BigDecimal("34386810.02"), target_node.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal 0, result.manual_insert_required_count
  end

  test "resolves new object parent from activity-like DOCX object rows" do
    activity_like_parent = @version.program_nodes.create!(
      node_type: "object",
      code: "03.04",
      display_number: "3.4",
      name: "Мероприятие 03.04 Строительство объектов водоснабжения",
      normalized_name: "мероприятие 03 04 строительство объектов водоснабжения",
      source_table_index: 0,
      source_row_index: 2,
      metadata: @parent.metadata.merge("finance_table_index" => 1)
    )
    @change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Новый ВЗУ",
      new_amount_rub: "100000.00",
      delta_rub: "100000.00",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "GROUPED_OBJECT",
        "match_status" => "MISSING_IN_DOCX",
        "group_key" => "101030400000000::100001::новый взу",
        "parent_activity_code" => "101030400000000",
        "object_code" => "100001",
        "row_number" => 20
      },
      confidence: "0.0"
    )

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    target_parent = result.target_program_version.program_nodes.find_by!(name: activity_like_parent.name)
    target_node = result.target_program_version.program_nodes.find_by!(name: "Новый ВЗУ")
    assert_equal target_parent, target_node.parent
    assert_equal BigDecimal("100000.0"), target_node.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal 0, result.manual_insert_required_count
  end

  test "falls back to main activity parent when coded activity is absent" do
    main_activity_like_parent = @version.program_nodes.create!(
      node_type: "object",
      code: "03",
      display_number: "3",
      name: "Основное мероприятие 03 Строительство объектов водоснабжения",
      normalized_name: "основное мероприятие 03 строительство объектов водоснабжения",
      source_table_index: 0,
      source_row_index: 2,
      metadata: @parent.metadata.merge("finance_table_index" => 1)
    )
    @change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Новый ВЗУ",
      new_amount_rub: "100000.00",
      delta_rub: "100000.00",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "GROUPED_OBJECT",
        "match_status" => "MISSING_IN_DOCX",
        "group_key" => "101030400000000::100001::новый взу",
        "parent_activity_code" => "101030400000000",
        "object_code" => "100001",
        "row_number" => 20
      },
      confidence: "0.0"
    )

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user).apply!

    target_parent = result.target_program_version.program_nodes.find_by!(name: main_activity_like_parent.name)
    target_node = result.target_program_version.program_nodes.find_by!(name: "Новый ВЗУ")
    assert_equal target_parent, target_node.parent
    assert_equal 0, result.manual_insert_required_count
  end

  test "uses shifted main activity parent for activity aggregate new rows" do
    program_root = @version.program_nodes.create!(
      node_type: "program",
      name: "Муниципальная программа",
      normalized_name: "муниципальная программа"
    )
    main_activity_like_parent = @version.program_nodes.create!(
      parent: program_root,
      node_type: "object",
      code: "01",
      display_number: "1",
      name: "Основное мероприятие 01. Создание условий для реализации полномочий органов местного самоуправления",
      normalized_name: "основное мероприятие 01 создание условий для реализации полномочий органов местного самоуправления",
      source_table_index: 0,
      source_row_index: 2,
      execution_period: "01.01.2026-31.12.2030",
      metadata: @parent.metadata.merge("finance_table_index" => 5)
    )
    %w[FEDERAL_BUDGET REGIONAL_BUDGET LOCAL_BUDGET].each do |source_type|
      main_activity_like_parent.funding_lines.create!(
        year: 2026,
        source_type: source_type,
        amount_rub: "0.00",
        metadata: { "source_table_index" => 0, "source_row_index" => 2, "source_cell_index" => 4 }
      )
    end
    main_activity_total_parent = @version.program_nodes.create!(
      parent: program_root,
      node_type: "main_activity",
      code: "01",
      display_number: "1",
      name: main_activity_like_parent.name,
      normalized_name: main_activity_like_parent.normalized_name,
      source_table_index: 0,
      source_row_index: 3,
      execution_period: "01.01.2026-31.12.2030",
      metadata: @parent.metadata.merge("finance_table_index" => 5, "source" => "finance_table")
    )
    previous_activity = @version.program_nodes.create!(
      parent: main_activity_total_parent,
      node_type: "object",
      code: "01.01",
      display_number: "1.1",
      name: "Мероприятие 01.01. Расходы на обеспечение деятельности",
      normalized_name: "мероприятие 01 01 расходы на обеспечение деятельности",
      source_table_index: 0,
      source_row_index: 4,
      execution_period: "01.01.2026-31.12.2030"
    )
    previous_activity.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "1000.00",
      metadata: { "source_table_index" => 0, "source_row_index" => 5, "source_cell_index" => 4 }
    )
    previous_total_row = @version.program_nodes.create!(
      parent: main_activity_total_parent,
      node_type: "activity",
      code: "01.01",
      display_number: "1.1",
      name: "Мероприятие 01.01. Расходы на обеспечение деятельности",
      normalized_name: "мероприятие 01 01 расходы на обеспечение деятельности",
      source_table_index: 0,
      source_row_index: 6,
      execution_period: "01.01.2026-31.12.2030",
      metadata: { "source" => "finance_table", "docx_source_raw_value" => "Итого:" }
    )
    following_activity = @version.program_nodes.create!(
      parent: main_activity_total_parent,
      node_type: "object",
      code: "01.03",
      display_number: "1.2",
      name: "Мероприятие 01.03. Расходы на обеспечение молодежной политики",
      normalized_name: "мероприятие 01 03 расходы на обеспечение молодежной политики",
      source_table_index: 0,
      source_row_index: 8,
      execution_period: "01.01.2026-31.12.2030"
    )
    following_total_row = @version.program_nodes.create!(
      parent: main_activity_total_parent,
      node_type: "activity",
      code: "01.03",
      display_number: "1.2",
      name: "Мероприятие 01.03. Расходы на обеспечение молодежной политики",
      normalized_name: "мероприятие 01 03 расходы на обеспечение молодежной политики",
      source_table_index: 0,
      source_row_index: 9,
      execution_period: "01.01.2026-31.12.2030",
      metadata: { "source" => "finance_table", "docx_source_raw_value" => "Итого:" }
    )
    @change_set.change_items.create!(
      change_type: "new_object",
      status: "confirmed",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Обеспечение деятельности муниципальных органов - комитет по молодежной политике",
      new_amount_rub: "5574845.99",
      delta_rub: "5574845.99",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "ACTIVITY_AGGREGATE",
        "match_status" => "MISSING_IN_DOCX",
        "group_key" => "136010200000000::136010200000000::обеспечение деятельности муниципальных органов - комитет по молодежной политике",
        "parent_activity_code" => "136010200000000",
        "object_code" => "136010200000000",
        "object_name" => "Обеспечение деятельности муниципальных органов - комитет по молодежной политике",
        "row_number" => 67
      },
      confidence: "0.0"
    )
    patch_client = CapturingPatchClient.new

    result = ChangeSetApplicationService.new(change_set: @change_set, user: @user, patch_client: patch_client).apply!

    target_root = result.target_program_version.program_nodes.find_by!(name: program_root.name)
    target_anchor = result.target_program_version.program_nodes.find_by!(name: main_activity_like_parent.name, node_type: "object")
    target_main_activity = result.target_program_version.program_nodes.find_by!(name: main_activity_total_parent.name, node_type: "main_activity")
    target_node = result.target_program_version.program_nodes.find_by!("name LIKE ?", "%комитет по молодежной политике%")
    target_following = result.target_program_version.program_nodes.find_by!(name: following_activity.name)
    target_previous_total_row = result.target_program_version.program_nodes.find_by!(source_row_index: previous_total_row.source_row_index)
    target_following_total_row = result.target_program_version.program_nodes.find_by!(source_row_index: following_total_row.source_row_index)
    assert_equal target_main_activity, target_node.parent
    assert_equal "1.1", result.target_program_version.program_nodes.find_by!(name: previous_activity.name, source_row_index: previous_activity.source_row_index).display_number
    assert_equal "1.2", target_node.display_number
    assert_equal "01.02", target_node.code
    assert_equal "Мероприятие 01.02. Обеспечение деятельности муниципальных органов - комитет по молодежной политике", target_node.name
    assert_equal "1.3", target_following.display_number
    assert_equal "1.1", target_previous_total_row.display_number
    assert_equal "1.3", target_following_total_row.display_number
    insertion = patch_client.changes["insert_objects"].find { |item| item["target_node_id"] == target_node.id }
    assert_equal 6, insertion["insert_after_row_index"]
    assert_equal "1", insertion["parent_display_number"]
    assert_equal "01.01.2026-31.12.2030", insertion["execution_period"]
    assert_equal ["FEDERAL_BUDGET", "REGIONAL_BUDGET", "LOCAL_BUDGET", "TOTAL"], insertion["rows"].map { |row| row["source_type"] }
    assert_equal "16724.55", BigDecimal(insertion["rows"].last["total_amount_rub"]).then { |amount| (amount / 1000).to_s("F") }
    display_update = patch_client.changes["text_updates"].find { |update| update["program_node_id"] == target_following.id && update["reason"] == "display_number" }
    assert_equal "1.3.", display_update["text"]
    total_display_update = patch_client.changes["text_updates"].find { |update| update["program_node_id"] == target_following_total_row.id && update["reason"] == "display_number" }
    assert_equal "1.3.", total_display_update["text"]
    refute patch_client.changes["text_updates"].any? { |update| update["program_node_id"] == target_previous_total_row.id && update["reason"] == "display_number" }
    assert_equal target_anchor.id, target_node.metadata["docx_anchor_parent_node_id"]
    assert_equal BigDecimal("5574845.99"), target_node.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal BigDecimal("5574845.99"), target_main_activity.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").amount_rub
    assert_equal 0, result.manual_insert_required_count
  end

  private

  class FakeInvalidPostExportValidator
    def validate(program_version:, generated_docx_attachment:, generated_docx_bytes:)
      {
        "status" => "invalid",
        "errors" => [
          { "code" => "passport_total_mismatch", "message" => "Паспортная сумма за 2028 не совпадает" }
        ],
        "warnings" => [],
        "passport" => {},
        "passport_sources" => {},
        "visual_render" => { "status" => "valid" }
      }
    end
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

  class CapturingPatchClient
    attr_reader :changes, :source_label

    def patch(source_document: nil, changes:, source_docx_bytes: nil, source_label: nil)
      @changes = changes
      @source_label = source_label
      DocxPatchClient::Result.new(
        payload: {
          "applied_count" => Array(changes["cell_updates"]).size,
          "skipped_count" => 0,
          "inserted_count" => 0,
          "skipped_insertions" => []
        },
        bytes: source_docx_bytes || source_document.file_attachment.download
      )
    end
  end

  def generated_docx_cell_text(bytes, row: 1, col: 4)
    Tempfile.create(["generated", ".docx"]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      stdout, stderr, status = Open3.capture3(
        ENV.fetch("PARSER_WORKER_PYTHON", "python3"),
        "-c",
        "from docx import Document; import sys; print(Document(sys.argv[1]).tables[0].cell(int(sys.argv[2]), int(sys.argv[3])).text)",
        file.path,
        row.to_s,
        col.to_s
      )
      assert status.success?, stderr
      stdout.strip
    end
  end

  def generated_docx_rows(bytes)
    Tempfile.create(["generated", ".docx"]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      stdout, stderr, status = Open3.capture3(
        ENV.fetch("PARSER_WORKER_PYTHON", "python3"),
        "-c",
        "from docx import Document; import json, sys; print(json.dumps([[c.text for c in r.cells] for r in Document(sys.argv[1]).tables[0].rows], ensure_ascii=False))",
        file.path
      )
      assert status.success?, stderr
      JSON.parse(stdout)
    end
  end
end
