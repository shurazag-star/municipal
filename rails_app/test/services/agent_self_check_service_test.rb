require "test_helper"

class AgentSelfCheckServiceTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "agent-self-check@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие ЖКХ",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @change_set = ChangeSet.create!(
      program_version: @version,
      status: "applied",
      summary: "Проверенный проект",
      created_by: @user,
      approved_by: @user,
      export_summary: {
        "manual_insert_required_count" => 0,
        "post_export_validation" => {
          "status" => "valid",
          "errors" => [],
          "visual_render" => { "status" => "valid" }
        }
      }
    )
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

  test "passes only when final document has no pending risk" do
    result = AgentSelfCheckService.new(change_set: @change_set).call

    assert_equal "passed", result["status"]
    assert_empty result["blocking_reasons"]
    assert_equal "passed", @change_set.reload.export_summary.dig("agent_self_check", "status")
  end

  test "fails when unresolved rows conflicts or manual insertions remain" do
    @change_set.change_items.create!(
      change_type: "amount_update",
      status: "needs_confirmation",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "100.00",
      new_amount_rub: "150.00",
      delta_rub: "50.00",
      source_reference: {},
      confidence: "0.5",
      requires_user_confirmation: true,
      user_confirmed: false,
      agent_resolution_status: "needs_clarification",
      agent_resolution_reason: "Не хватает основания в документах."
    )
    @change_set.update!(
      export_summary: @change_set.export_summary.merge(
        "manual_insert_required_count" => 2,
        "source_conflicts" => [{ "object_name" => "ВЗУ Черусти" }]
      )
    )

    result = AgentSelfCheckService.new(change_set: @change_set).call

    assert_equal "failed", result["status"]
    assert_includes result["blocking_reasons"], "есть строки, которые агент не смог надежно разобрать"
    assert_includes result["blocking_reasons"], "есть нерешенные конфликты Excel/PDF"
    assert_includes result["blocking_reasons"], "есть новые объекты для дополнительной проверки"
  end

  test "does not block resolved Excel PDF conflicts" do
    @change_set.update!(
      export_summary: @change_set.export_summary.merge(
        "source_conflicts" => [
          { "object_name" => "ВЗУ Черусти", "year" => 2028, "source_type" => "LOCAL_BUDGET" }
        ],
        "source_resolution" => {
          "priority" => "xlsx_finance",
          "resolved_conflicts" => [
            { "object_name" => "ВЗУ Черусти", "year" => 2028, "source_type" => "LOCAL_BUDGET" }
          ]
        }
      )
    )

    result = AgentSelfCheckService.new(change_set: @change_set).call

    assert_equal "passed", result["status"]
    assert_not_includes result["blocking_reasons"], "есть нерешенные конфликты Excel/PDF"
  end

  test "blocks when Excel target model coverage is unsafe" do
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      status: "completed",
      summary: {
        "source_mode" => "xlsx_target",
        "external_target_model" => {
          "status" => "blocked",
          "blocking_reasons" => ["Excel-цель покрывает 50.00% объектов программы"]
        }
      }
    )
    @change_set.update!(analysis_session: session)

    result = AgentSelfCheckService.new(change_set: @change_set).call

    assert_equal "failed", result["status"]
    assert_includes result["blocking_reasons"], "Excel-цель не покрывает объекты программы достаточно надежно"
  end

  test "blocks when active DOCX document profile failed" do
    @version.update!(
      import_summary: {
        "municipal_document_profile_status" => "failed",
        "municipal_document_profile_confidence" => "0.40",
        "municipal_document_profile_warnings" => ["Не найдены строки финансирования DOCX"]
      }
    )

    result = AgentSelfCheckService.new(change_set: @change_set).call

    assert_equal "failed", result["status"]
    assert_includes result["blocking_reasons"], "структура DOCX-программы распознана недостаточно надежно"
  end

  test "blocks when PDF patch ledger is not ready" do
    session = AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      status: "completed",
      summary: {
        "source_mode" => "pdf_patch",
        "pdf_patch_ledger" => {
          "status" => "blocked",
          "blocking_reasons" => ["PDF содержит строки, которые не сопоставлены с объектами программы"]
        }
      }
    )
    @change_set.update!(analysis_session: session)

    result = AgentSelfCheckService.new(change_set: @change_set).call

    assert_equal "failed", result["status"]
    assert_includes result["blocking_reasons"], "PDF-журнал частичных правок не готов к применению"
  end

  test "blocks when active changes are attached to summary total rows" do
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

    result = AgentSelfCheckService.new(change_set: @change_set).call

    assert_equal "failed", result["status"]
    assert_includes result["blocking_reasons"], "есть изменения, ошибочно привязанные к итоговым строкам"
  end
end
