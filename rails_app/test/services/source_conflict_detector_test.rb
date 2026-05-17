require "test_helper"

class SourceConflictDetectorTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "source-conflicts@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
  end

  test "detects conflicting XLSX and PDF amounts for same object year and source" do
    xlsx = source_document!("xlsx_finance", "Финансы.xlsx")
    pdf = source_document!("pdf_agreement", "Соглашение.pdf")
    results = [
      match_result(xlsx, "ВЗУ Черусти", 2027, "LOCAL_BUDGET", "12000000.00"),
      match_result(pdf, "ВЗУ Черусти", 2027, "LOCAL_BUDGET", "15000000.00")
    ]

    conflicts = SourceConflictDetector.new(match_results: results).conflicts

    assert_equal 1, conflicts.size
    conflict = conflicts.first
    assert_equal "ВЗУ Черусти", conflict.fetch("object_name")
    assert_equal 2027, conflict.fetch("year")
    assert_equal "LOCAL_BUDGET", conflict.fetch("source_type")
    assert_equal "12000000.00", conflict.dig("sources", "xlsx_finance", "amount_rub")
    assert_equal "15000000.00", conflict.dig("sources", "pdf_agreement", "amount_rub")
  end

  private

  def source_document!(document_type, filename)
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: document_type,
      filename: filename,
      status: "parsed",
      parsed_payload: {}
    )
  end

  def match_result(source_document, object_name, year, source_type, amount)
    ExternalSourceMatcher::MatchResult.new(
      source_document: source_document,
      external_group: { "object_name" => object_name },
      funding_entries: [
        { "year" => year, "source_type" => source_type, "amount_rub" => BigDecimal(amount) }
      ],
      source_reference: {
        "object_name" => object_name,
        "document_type" => source_document.document_type
      },
      requires_user_confirmation: false,
      confidence: BigDecimal("1.0"),
      match_status: "MATCH_EXACT_NAME"
    )
  end
end
