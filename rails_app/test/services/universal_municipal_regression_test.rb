require "test_helper"

class UniversalMunicipalRegressionTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "universal-regression@example.com")
    @organization = @user.organization
    @organization.update!(
      name: "Городской округ Примерный",
      municipality_name: "городского округа Примерный",
      region_name: "Краснодарский край"
    )
    @program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие коммунальной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @program.update!(current_version: @version)
    @node = @version.program_nodes.create!(
      node_type: "object",
      name: "Водозаборный узел Центральный",
      normalized_name: "водозаборный узел центральный",
      display_number: "1.1.1"
    )
  end

  test "Excel target from another region updates regional budget and zeroes omitted DOCX source" do
    @node.funding_lines.create!(year: 2026, source_type: "REGIONAL_BUDGET", amount_rub: "100.00")
    @node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "50.00")
    excel = excel_document!(
      object_name: "Водозаборный узел Центральный",
      funding: { "2026::краевой бюджет" => "120.00" }
    )
    session = analysis_session!(excel, "xlsx_target")

    match_results = ExternalSourceMatcher.new(analysis_session: session, source_document: excel).match!
    change_set = ChangeSetBuilder.new(analysis_session: session, match_results: match_results).build!

    items = change_set.change_items.order(:source_type).to_a
    assert_equal ["LOCAL_BUDGET", "REGIONAL_BUDGET"], items.map(&:source_type).sort
    regional = items.find { |item| item.source_type == "REGIONAL_BUDGET" }
    local_zero = items.find { |item| item.source_type == "LOCAL_BUDGET" }
    assert_equal BigDecimal("120.00"), regional.new_amount_rub
    assert_equal BigDecimal("0"), local_zero.new_amount_rub
    assert_equal true, local_zero.source_reference["target_model_absent_in_excel"]
  end

  test "municipal document profile captures shifted table columns and republican budget alias" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа другого муниципалитета.docx",
      status: "parsed",
      parsed_payload: {
        "program" => { "name" => "Другая программа" },
        "passport_total_cell_coordinates" => { "2026" => { "table_index" => 2, "row_index" => 4, "cell_index" => 10 } },
        "funding_lines" => [
          {
            "source_table_index" => 9,
            "source_row_index" => 21,
            "source_cell_index" => 6,
            "total_cell_index" => 7,
            "year_cell_indexes" => { "2026" => 8, "2027" => 9 },
            "source_type" => "республиканский бюджет"
          }
        ]
      }
    )

    profile = DocumentProfileBuilder.new(source_document: document).build!

    assert_equal "active", profile.status
    assert_equal 9, profile.schema_json.dig("docx_finance_tables", 0, "table_index")
    assert_equal 6, profile.schema_json.dig("docx_finance_tables", 0, "source_col")
    assert_equal({ "2026" => 8, "2027" => 9 }, profile.schema_json.dig("docx_finance_tables", 0, "year_cols"))
    assert profile.schema_json["funding_source_aliases"].key?("REGIONAL_BUDGET")
  end

  test "PDF patch from another municipality changes only stated row and does not zero omitted years" do
    @node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
    @node.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "200.00")
    pdf = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение другого региона.pdf",
      status: "parsed",
      parsed_payload: {
        "changes" => [
          {
            "object_name" => "Водозаборный узел Центральный",
            "year" => 2026,
            "source_type" => "местный бюджет",
            "amount_mode" => "delta_plus",
            "delta_rub" => "50.00",
            "confidence" => "0.95"
          }
        ]
      }
    )
    session = analysis_session!(pdf, "pdf_patch")

    match_results = ExternalSourceMatcher.new(analysis_session: session, source_document: pdf).match!
    change_set = ChangeSetBuilder.new(analysis_session: session, match_results: match_results).build!

    item = change_set.change_items.sole
    assert_equal 2026, item.year
    assert_equal BigDecimal("150.00"), item.new_amount_rub
    assert_equal BigDecimal("50.00"), item.delta_rub
    assert_nil change_set.change_items.find_by(year: 2027)
  end

  private

  def analysis_session!(document, source_mode)
    AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      goal: "Регрессионная проверка универсальности",
      selected_source_document_ids: [document.id],
      summary: { "source_mode" => source_mode }
    )
  end

  def excel_document!(object_name:, funding:)
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы другого региона.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "object_groups" => [
          {
            "group_key" => "01::OBJ-1::#{object_name}",
            "status" => "GROUPED_OBJECT",
            "funding" => funding,
            "rows" => [
              {
                "row_number" => 12,
                "row_type" => "OBJECT_LEAF_ROW",
                "object_code" => "OBJ-1",
                "object_name" => object_name,
                "funding" => funding,
                "raw_values" => { "Наименование объекта" => object_name }
              }
            ]
          }
        ]
      }
    )
  end
end
