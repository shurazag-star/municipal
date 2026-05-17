require "test_helper"

class DocumentProfileBuilderTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "document-profile@example.com")
    @organization = @user.organization
  end

  test "builds active DOCX profile from passport and finance coordinates" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed",
      parsed_payload: docx_payload
    )

    profile = DocumentProfileBuilder.new(source_document: document).build!

    assert_equal "active", profile.status
    assert_equal "docx_program", profile.profile_type
    assert_operator profile.confidence, :>=, BigDecimal("0.80")
    assert_equal [6], profile.schema_json.dig("docx_finance_tables").map { |table| table["table_index"] }
    assert_equal({ "2026" => 5, "2027" => 6 }, profile.schema_json.dig("docx_finance_tables", 0, "year_cols"))
    assert_equal true, profile.schema_json.dig("passport_table", "detected")
  end

  test "marks low confidence DOCX profile as failed with warnings" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Плохая программа.docx",
      status: "parsed",
      parsed_payload: { "program" => { "name" => "Без таблиц" }, "nodes" => [] }
    )

    profile = DocumentProfileBuilder.new(source_document: document).build!

    assert_equal "failed", profile.status
    assert_operator profile.confidence, :<, BigDecimal("0.65")
    assert_includes profile.warnings, "Не найдены строки финансирования DOCX"
    assert_includes profile.warnings, "Не найден паспорт программы"
  end

  test "builds PDF agreement profile with table profile and control sums" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение.pdf",
      status: "parsed",
      parsed_payload: {
        "changes" => [{ "object_name" => "Объект", "year" => 2026, "source_type" => "LOCAL_BUDGET", "amount_rub" => "5.00" }],
        "pdf_profile" => {
          "table_count" => 1,
          "detected_table_types" => ["continued_appendix_budget_table"],
          "tables" => [
            {
              "table_type" => "continued_appendix_budget_table",
              "page_number" => 9,
              "row_count" => 2
            }
          ]
        },
        "pdf_control_sums" => {
          "status" => "passed",
          "failed_check_count" => 0,
          "checks" => [
            {
              "year" => 2026,
              "source_type" => "LOCAL_BUDGET",
              "detail_total_rub" => "5.00",
              "control_total_rub" => "5.00",
              "difference_rub" => "0.00",
              "status" => "passed"
            }
          ]
        }
      }
    )

    profile = DocumentProfileBuilder.new(source_document: document).build!

    assert_equal "active", profile.status
    assert_equal "pdf_agreement", profile.profile_type
    assert_equal 1, profile.schema_json.dig("pdf_patch", "changes_count")
    assert_equal "passed", profile.schema_json.dig("pdf_patch", "control_sums", "status")
    assert_equal ["continued_appendix_budget_table"], profile.schema_json.dig("pdf_patch", "detected_table_types")
  end

  test "marks PDF agreement profile failed when control sums fail" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение.pdf",
      status: "parsed",
      parsed_payload: {
        "changes" => [{ "object_name" => "Объект", "year" => 2026, "source_type" => "LOCAL_BUDGET", "amount_rub" => "5.00" }],
        "pdf_profile" => { "table_count" => 1, "detected_table_types" => ["continued_appendix_budget_table"], "tables" => [] },
        "pdf_control_sums" => {
          "status" => "failed",
          "failed_check_count" => 1,
          "checks" => [
            {
              "year" => 2026,
              "source_type" => "LOCAL_BUDGET",
              "detail_total_rub" => "5.00",
              "control_total_rub" => "6.00",
              "difference_rub" => "-1.00",
              "status" => "failed"
            }
          ]
        }
      }
    )

    profile = DocumentProfileBuilder.new(source_document: document).build!

    assert_equal "failed", profile.status
    assert_includes profile.warnings, "Контрольные суммы PDF-таблицы не сходятся"
  end

  private

  def docx_payload
    {
      "program" => { "name" => "Развитие ЖКХ", "period_start_year" => 2026, "period_end_year" => 2030 },
      "passport_totals_by_year" => { "2026" => "150.00", "2027" => "200.00" },
      "passport_total_cell_coordinates" => { "2026" => { "table_index" => 1, "row_index" => 3, "cell_index" => 2 } },
      "funding_lines" => [
        {
          "source_table_index" => 6,
          "source_row_index" => 12,
          "source_cell_index" => 3,
          "total_cell_index" => 4,
          "year_cell_indexes" => { "2026" => 5, "2027" => 6 },
          "source_type" => "LOCAL_BUDGET"
        }
      ]
    }
  end
end
