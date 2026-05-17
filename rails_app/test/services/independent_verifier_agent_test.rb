require "test_helper"

class IndependentVerifierAgentTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "independent-verifier@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "changed")
    @object = @version.program_nodes.create!(node_type: "object", name: "ВЗУ Черусти", normalized_name: "взу черусти")
    @change_set = ChangeSet.create!(program_version: @version, target_program_version: @version, status: "applied", summary: "OK", created_by: @user)
    @change_set.generated_docx_attachment.attach(
      io: StringIO.new("docx"),
      filename: "result.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    @change_set.change_report_attachment.attach(
      io: StringIO.new("report"),
      filename: "report.html",
      content_type: "text/html"
    )
  end

  test "passes when independent checks have inspectable evidence" do
    result = IndependentVerifierAgent.new(
      change_set: @change_set,
      target_program_version: @version,
      export_summary: valid_export_summary
    ).verify

    assert_equal "passed", result["status"]
    assert_empty result["blocking_reasons"]
    assert result["checks"].all? { |check| check["passed"] }
  end

  test "fails on numeric object labels and blocked external target model" do
    @object.update!(name: "7388096.53313196.0134386810.023247950.0")
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      status: "completed",
      summary: {
        "external_target_model" => {
          "status" => "blocked",
          "blocking_reasons" => ["Excel-цель покрывает мало объектов"]
        }
      }
    )
    @change_set.update!(analysis_session: session)

    result = IndependentVerifierAgent.new(
      change_set: @change_set,
      target_program_version: @version,
      export_summary: valid_export_summary
    ).verify

    assert_equal "failed", result["status"]
    assert_includes result["blocking_reasons"], "в дереве программы есть числовые названия объектов"
    assert_includes result["blocking_reasons"], "внешняя целевая модель не прошла независимую проверку"
  end

  test "fails when active changes point to summary total rows" do
    total_node = @version.program_nodes.create!(
      node_type: "object",
      name: "Итого по подпрограмме",
      display_number: "Итого по подпрограмме"
    )
    @change_set.change_items.create!(
      program_node: total_node,
      change_type: "amount_update",
      status: "confirmed",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "100.00",
      new_amount_rub: "150.00",
      delta_rub: "50.00",
      source_reference: {},
      confidence: "1.0",
      agent_resolution_status: "resolved"
    )

    result = IndependentVerifierAgent.new(
      change_set: @change_set,
      target_program_version: @version,
      export_summary: valid_export_summary
    ).verify

    assert_equal "failed", result["status"]
    assert_includes result["blocking_reasons"], "часть изменений привязана к итоговым строкам, а не к объектам"
    assert_includes result.dig("evidence", "summary_row_change_item_ids"), @change_set.change_items.last.id
  end

  private

  def valid_export_summary
    {
      "manual_insert_required_count" => 0,
      "post_export_validation" => {
        "status" => "valid",
        "errors" => [],
        "visual_render" => { "status" => "valid" }
      },
      "docx_patch" => { "applied_count" => 1, "inserted_count" => 0 }
    }
  end
end
