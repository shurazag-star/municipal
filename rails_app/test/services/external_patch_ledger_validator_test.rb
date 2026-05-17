require "test_helper"

class ExternalPatchLedgerValidatorTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "external-patch-ledger@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    @source_version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @source_node = @source_version.program_nodes.create!(node_type: "object", name: "ВЗУ Черусти", normalized_name: "взу черусти")
    @pdf = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    @session = @organization.analysis_sessions.create!(
      user: @user,
      program_version: @source_version,
      source_mode: "pdf_patch",
      summary: { "source_mode" => "pdf_patch" }
    )
    @change_set = ChangeSet.create!(
      analysis_session: @session,
      program_version: @source_version,
      source_document: @pdf,
      created_by: @user,
      status: "draft",
      summary: "PDF patch"
    )
    @item = @change_set.change_items.create!(
      program_node: @source_node,
      change_type: "amount_update",
      year: 2027,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: BigDecimal("1000"),
      new_amount_rub: BigDecimal("1500"),
      delta_rub: BigDecimal("500"),
      source_reference: {
        "source_document_id" => @pdf.id,
        "filename" => @pdf.filename,
        "document_type" => "pdf_agreement",
        "page_number" => 3,
        "amount_mode" => "delta_plus",
        "evidence_text" => "увеличить на 500"
      }
    )
    @target_version = @program.program_versions.create!(created_by: @user, version_number: 2, status: "changed")
    @target_node = @target_version.program_nodes.create!(
      node_type: "object",
      name: "ВЗУ Черусти",
      normalized_name: "взу черусти",
      metadata: { "source_program_node_id" => @source_node.id }
    )
    @target_node.funding_lines.create!(year: 2027, source_type: "local_budget", amount_rub: BigDecimal("1500"))
  end

  test "builds and validates pdf operation after export" do
    ledger = ExternalPatchLedgerBuilder.new(change_set: @change_set, target_program_version: @target_version).build

    assert_equal "ready", ledger["status"]
    entry = ledger["entries"].sole
    assert_equal @item.id, entry["change_item_id"]
    assert_equal "1000.00", entry["before_rub"]
    assert_equal "1500.00", entry["expected_after_rub"]

    validation = ExternalPatchLedgerValidator.new(
      change_set: @change_set,
      target_program_version: @target_version,
      ledger: ledger,
      post_export_validation: { "status" => "valid", "errors" => [] }
    ).validate

    assert_equal "passed", validation["status"]
    assert_equal "passed", validation["entries"].sole["validation_status"]
  end

  test "fails when target amount does not match expected pdf operation" do
    @target_node.funding_lines.first.update!(amount_rub: BigDecimal("1400"))
    ledger = ExternalPatchLedgerBuilder.new(change_set: @change_set, target_program_version: @target_version).build

    validation = ExternalPatchLedgerValidator.new(
      change_set: @change_set,
      target_program_version: @target_version,
      ledger: ledger,
      post_export_validation: { "status" => "valid", "errors" => [] }
    ).validate

    assert_equal "failed", validation["status"]
    assert_includes validation["blocking_reasons"], "Не все операции PDF подтверждены расчетным деревом и DOCX-проверкой"
  end
end
