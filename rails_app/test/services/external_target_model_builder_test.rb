require "test_helper"

class ExternalTargetModelBuilderTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "external-target-model@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @program.update!(current_version: @version)
    @matched_node = @version.program_nodes.create!(node_type: "object", name: "ВЗУ Черусти", normalized_name: "взу черусти")
    @absent_node = @version.program_nodes.create!(node_type: "object", name: "ВЗУ Рошаль", normalized_name: "взу рошаль")
    @matched_node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
    @absent_node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "50.00")
    @document = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "xlsx_finance", filename: "Финансы.xlsx", status: "parsed")
    @session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      selected_source_document_ids: [@document.id],
      summary: { "source_mode" => "xlsx_target" }
    )
  end

  test "builds target ledger and coverage metrics from matched Excel rows" do
    match_result = ExternalSourceMatcher::MatchResult.new(
      source_document: @document,
      program_node: @matched_node,
      external_group: { "object_name" => "ВЗУ Черусти", "object_code" => "1000004207.1000005123" },
      funding_entries: [{ "year" => 2026, "source_type" => "LOCAL_BUDGET", "amount_rub" => BigDecimal("125.00"), "row_number" => 61 }],
      source_reference: { "row_number" => 61 },
      confidence: BigDecimal("1.0"),
      match_status: "MATCH_EXACT_NAME"
    )

    model = ExternalTargetModelBuilder.new(analysis_session: @session, match_results: [match_result]).build

    assert_equal "xlsx_target", model["source_mode"]
    assert_equal 1, model["entries"].size
    assert_equal "125.00", model["entries"].first["amount_rub"]
    assert_equal 1, model["coverage"]["excel_object_rows_total"]
    assert_equal 1, model["coverage"]["excel_object_rows_matched"]
    assert_equal 2, model["coverage"]["baseline_objects_total"]
    assert_equal 1, model["coverage"]["baseline_objects_absent_from_excel"]
    assert_equal "ready", model["status"]
    assert_empty model["blocking_reasons"]
    assert_includes model["warnings"].join(" "), "отсутствующие объекты DOCX будут обнулены"
  end
end
