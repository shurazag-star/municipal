require "test_helper"

class ChangeSetReportBuilderTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "report-builder@example.com")
    @program = MunicipalProgram.create!(
      organization: @user.organization,
      name: "Развитие инженерной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "changed")
    @change_set = ChangeSet.create!(
      program_version: @version,
      target_program_version: @version,
      status: "needs_manual_review",
      summary: "Проверка отчета",
      created_by: @user
    )
  end

  test "does not render amount new_value as object label" do
    result_node = @version.program_nodes.create!(
      node_type: "result",
      name: "Приобретено коммунальной техники",
      normalized_name: "приобретено коммунальной техники"
    )
    @change_set.change_items.create!(
      program_node: result_node,
      change_type: "amount_update",
      status: "confirmed",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "0",
      new_value: "7388096.53",
      new_amount_rub: "7388096.53",
      delta_rub: "7388096.53",
      confidence: "0.5"
    )

    html = ChangeSetReportBuilder.new(
      change_set: @change_set,
      target_program_version: @version,
      export_summary: {}
    ).html

    assert_no_match(%r{<td>7388096\.53</td>}, html)
    assert_match(%r{<td>Не определено</td>}, html)
  end
end
