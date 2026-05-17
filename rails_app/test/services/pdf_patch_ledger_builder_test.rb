require "test_helper"

class PdfPatchLedgerBuilderTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "pdf-ledger@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @node = @version.program_nodes.create!(node_type: "object", name: "ВЗУ Черусти", normalized_name: "взу черусти")
    @pdf = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    @session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      selected_source_document_ids: [@pdf.id],
      summary: { "source_mode" => "pdf_patch" }
    )
  end

  test "builds inspectable partial patch ledger for matched PDF changes" do
    result = match_result(program_node: @node, requires_user_confirmation: false)

    ledger = PdfPatchLedgerBuilder.new(analysis_session: @session, match_results: [result]).build

    assert_equal "ready", ledger["status"]
    assert_equal "pdf_is_partial_patch_not_target_model", ledger["policy"]
    assert_equal 1, ledger["matched_count"]
    assert_equal 0, ledger["unmatched_count"]
    entry = ledger["entries"].sole
    assert_equal @pdf.id, entry["source_document_id"]
    assert_equal @node.id, entry["program_node_id"]
    assert_equal "matched", entry["status"]
    assert_equal "delta_plus", entry["amount_mode"]
    assert_equal "500.00", entry["delta_rub"]
  end

  test "blocks PDF patch ledger when a PDF row is not matched" do
    result = match_result(program_node: nil, requires_user_confirmation: true, match_status: "MISSING_IN_DOCX")

    ledger = PdfPatchLedgerBuilder.new(analysis_session: @session, match_results: [result]).build

    assert_equal "blocked", ledger["status"]
    assert_equal 1, ledger["unmatched_count"]
    assert_includes ledger["blocking_reasons"], "PDF содержит строки, которые не сопоставлены с объектами программы"
  end

  test "blocks PDF patch ledger when PDF control sums failed" do
    @pdf.update!(
      parsed_payload: {
        "pdf_control_sums" => {
          "status" => "failed",
          "failed_check_count" => 1,
          "checks" => [
            {
              "year" => 2026,
              "source_type" => "LOCAL_BUDGET",
              "detail_total_rub" => "500.00",
              "control_total_rub" => "600.00",
              "difference_rub" => "-100.00",
              "status" => "failed"
            }
          ]
        }
      }
    )
    result = match_result(program_node: @node, requires_user_confirmation: false)

    ledger = PdfPatchLedgerBuilder.new(analysis_session: @session, match_results: [result]).build

    assert_equal "blocked", ledger["status"]
    assert_includes ledger["blocking_reasons"], "Контрольные суммы PDF-таблицы не сходятся"
    assert_equal "failed", ledger.dig("documents", 0, "pdf_control_sums", "status")
  end

  private

  def match_result(program_node:, requires_user_confirmation:, match_status: "MATCH_EXACT_NAME")
    ExternalSourceMatcher::MatchResult.new(
      source_document: @pdf,
      program_node: program_node,
      external_group: {
        "object_name" => "ВЗУ Черусти",
        "pdf_changes" => [{ "page_number" => 4, "evidence_text" => "Увеличить финансирование" }]
      },
      funding_entries: [
        {
          "year" => 2026,
          "source_type" => "LOCAL_BUDGET",
          "amount_rub" => BigDecimal("500.00"),
          "amount_mode" => "delta_plus",
          "delta_rub" => "500.00",
          "page_number" => 4,
          "evidence_text" => "Увеличить финансирование"
        }
      ],
      source_reference: {
        "filename" => @pdf.filename,
        "document_type" => "pdf_agreement",
        "object_name" => "ВЗУ Черусти",
        "page_number" => 4,
        "evidence_text" => "Увеличить финансирование"
      },
      requires_user_confirmation: requires_user_confirmation,
      confidence: BigDecimal("0.96"),
      match_status: match_status
    )
  end
end
