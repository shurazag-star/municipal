require "test_helper"

class AnalysisSessionRunnerTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "analysis-runner@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие инженерной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @program.update!(current_version: @version)
    @node = @version.program_nodes.create!(
      node_type: "object",
      name: "ВЗУ Черусти",
      normalized_name: "взу черусти",
      display_number: "1.1.1"
    )
    @node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
  end

  test "runs selected sources, stores summary, and creates changeset" do
    document = excel_document!("ВЗУ Черусти", "1000004207.1000005123", "2026::LOCAL_BUDGET" => "150.00")
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      goal: "Провести анализ",
      selected_source_document_ids: [document.id]
    )

    assert_difference "ChangeSet.count", 1 do
      AnalysisSessionRunner.new(session).run!
    end

    session.reload
    assert_equal "completed", session.status
    assert_equal "xlsx_target", session.summary["source_mode"]
    assert_equal 1, session.summary["matched_count"]
    assert_equal 1, session.summary["change_items_count"]
    assert_equal session, ChangeSet.last.analysis_session
  end

  test "summarizes parsed PDF agreement without structured changes instead of crashing" do
    pdf = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      goal: "Проверить PDF",
      selected_source_document_ids: [pdf.id]
    )

    AnalysisSessionRunner.new(session).run!

    session.reload
    assert_equal "completed", session.status
    assert_equal "pdf_patch", session.summary["source_mode"]
    assert_equal 1, session.summary["unsupported_source_count"]
    assert_equal 0, session.summary["change_items_count"]
  end

  test "stores PDF patch ledger when PDF agreement is used as partial patch source" do
    @node.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
    pdf = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение.pdf",
      status: "parsed",
      parsed_payload: {
        "changes" => [
          {
            "object_name" => "ВЗУ Черусти",
            "source_type" => "LOCAL_BUDGET",
            "amount_mode" => "delta_plus",
            "delta_rub" => "50.00",
            "year" => 2027,
            "confidence" => "0.95",
            "page_number" => 4
          }
        ]
      }
    )
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      goal: "Проверить PDF",
      selected_source_document_ids: [pdf.id],
      summary: { "source_mode" => "pdf_patch" }
    )

    AnalysisSessionRunner.new(session).run!

    ledger = session.reload.summary["pdf_patch_ledger"]
    assert_equal "ready", ledger["status"]
    assert_equal "pdf_is_partial_patch_not_target_model", ledger["policy"]
    assert_equal 1, ledger["entries"].size
  end

  test "uses PDF as evidence without adding PDF rows in Excel target mode" do
    excel = excel_document!("ВЗУ Черусти", "1000004207.1000005123", "2026::LOCAL_BUDGET" => "150.00")
    pdf = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение.pdf",
      status: "parsed",
      parsed_payload: {
        "changes" => [
          {
            "object_name" => "ВЗУ Черусти",
            "source_type" => "LOCAL_BUDGET",
            "amount_mode" => "delta_plus",
            "delta_rub" => "50.00",
            "year" => 2026,
            "confidence" => "0.95",
            "page_number" => 2
          }
        ]
      }
    )
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      goal: "Excel как цель, PDF как подтверждение",
      selected_source_document_ids: [excel.id],
      source_mode: "xlsx_target_with_pdf_evidence",
      summary: {
        "source_mode" => "xlsx_target_with_pdf_evidence",
        "calculation_source_document_ids" => [excel.id],
        "evidence_source_document_ids" => [pdf.id]
      }
    )

    AnalysisSessionRunner.new(session).run!

    session.reload
    assert_equal "xlsx_target_with_pdf_evidence", session.summary["source_mode"]
    assert_equal [excel.id], session.summary["source_document_ids"]
    assert_equal 1, session.summary["evidence_matched_count"]
    assert_equal 1, session.summary["change_items_count"]
    assert_equal 1, session.summary["source_conflicts_count"]
    assert_equal ["xlsx_finance", "pdf_agreement"].sort, session.summary["source_conflicts"].first["sources"].keys.sort
  end

  private

  def excel_document!(object_name, object_code, funding)
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "object_groups" => [
          {
            "group_key" => "01::#{object_code}::#{object_name}",
            "status" => "GROUPED_OBJECT",
            "funding" => funding,
            "rows" => [
              {
                "row_number" => 61,
                "row_type" => "OBJECT_LEAF_ROW",
                "parent_activity_code" => "01",
                "object_code" => object_code,
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
