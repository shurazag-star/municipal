require "test_helper"

class AgentAutonomousResolverTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "resolver@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие инженерной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @change_set = ChangeSet.create!(
      program_version: @version,
      status: "draft",
      summary: "Проверка резолвера",
      created_by: @user
    )
  end

  test "resolves residual Excel rows into parent activity without manual clarification" do
    subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 1",
      display_number: "1"
    )
    @version.program_nodes.create!(
      parent: subprogram,
      node_type: "activity",
      code: "02.13",
      display_number: "2.13",
      name: "Капитальные вложения"
    )
    item = @change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Неуказанное направление",
      new_amount_rub: "7388096.53",
      delta_rub: "7388096.53",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "UNASSIGNED_RESIDUAL",
        "match_status" => "UNASSIGNED_RESIDUAL",
        "group_key" => "UNASSIGNED_RESIDUAL::101021300000000::14",
        "parent_activity_code" => "101021300000000",
        "object_code" => "0000000000.0000000000",
        "row_number" => 14
      },
      confidence: "0.0"
    )

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!

    assert_equal "resolved", item.reload.agent_resolution_status
    assert_equal "confirmed", item.status
    assert_match(/остаточн/i, item.agent_resolution_reason)
    assert_equal "residual_parent_code", item.agent_resolution_evidence["resolution_pass"]
  end

  test "blocks residual Excel rows when parent activity is absent" do
    item = @change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Неуказанное направление",
      new_amount_rub: "7388096.53",
      delta_rub: "7388096.53",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "UNASSIGNED_RESIDUAL",
        "match_status" => "UNASSIGNED_RESIDUAL",
        "group_key" => "UNASSIGNED_RESIDUAL::101021300000000::14",
        "parent_activity_code" => "101021300000000",
        "object_code" => "0000000000.0000000000",
        "row_number" => 14
      },
      confidence: "0.0"
    )

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!

    assert_equal "needs_clarification", item.reload.agent_resolution_status
    assert_match(/остаточн|неуказан/i, item.agent_resolution_reason)
  end

  test "does not resolve residual to same display number in another subprogram" do
    wrong_subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 2",
      display_number: "2"
    )
    @version.program_nodes.create!(
      parent: wrong_subprogram,
      node_type: "activity",
      code: "02.02",
      display_number: "2.2",
      name: "Мероприятие 02.02 другой подпрограммы"
    )
    another_wrong_subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 4",
      display_number: "4"
    )
    @version.program_nodes.create!(
      parent: another_wrong_subprogram,
      node_type: "activity",
      code: "02.02",
      display_number: "2.2",
      name: "Мероприятие 02.02 еще одной подпрограммы"
    )
    item = @change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2027,
      source_type: "LOCAL_BUDGET",
      new_value: "Выполнение работ по установке автоматизированных систем контроля за газовой безопасностью",
      new_amount_rub: "1000000.00",
      delta_rub: "1000000.00",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "UNASSIGNED_RESIDUAL",
        "match_status" => "UNASSIGNED_RESIDUAL",
        "group_key" => "UNASSIGNED_RESIDUAL::105020200000000::166",
        "parent_activity_code" => "105020200000000",
        "object_code" => "0000000000.0000000000",
        "row_number" => 166
      },
      confidence: "0.0"
    )

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!

    assert_equal "needs_clarification", item.reload.agent_resolution_status
  end

  test "resolves coded Excel new objects even when matcher asks confirmation" do
    subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 3",
      display_number: "3"
    )
    @version.program_nodes.create!(
      parent: subprogram,
      node_type: "activity",
      code: "01.25",
      display_number: "1.6",
      name: "Строительство и реконструкция объектов теплоснабжения"
    )
    item = @change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Строительство блочно-модульной котельной",
      new_amount_rub: "1757008.12",
      delta_rub: "1757008.12",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "GROUPED_OBJECT",
        "match_status" => "NEEDS_CONFIRMATION",
        "group_key" => "103012500000000::4036470831.4036471081::Строительство блочно-модульной котельной",
        "parent_activity_code" => "103012500000000",
        "object_code" => "4036470831.4036471081",
        "object_name" => "Строительство блочно-модульной котельной",
        "row_number" => 55
      },
      confidence: "0.50"
    )

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!

    assert_equal "resolved", item.reload.agent_resolution_status
    assert_equal "confirmed", item.status
    assert_equal "new_object_parent_code", item.agent_resolution_evidence["resolution_pass"]
  end

  test "does not auto confirm ambiguous PDF object as a new object" do
    item = @change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2027,
      source_type: "LOCAL_BUDGET",
      new_value: "ВЗУ",
      new_amount_rub: "1000000.00",
      delta_rub: "1000000.00",
      source_reference: {
        "document_type" => "pdf_agreement",
        "group_status" => "PDF_AGREEMENT_CHANGE",
        "match_status" => "NEEDS_CONFIRMATION",
        "group_key" => "pdf::::ВЗУ",
        "object_name" => "ВЗУ",
        "page_number" => 1
      },
      confidence: "0.50"
    )

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!

    assert_equal "needs_clarification", item.reload.agent_resolution_status
    assert_match(/уточн/i, item.agent_resolution_reason)
  end

  test "resolves coded Excel new objects by unique activity code fallback" do
    subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 5",
      display_number: "5"
    )
    @version.program_nodes.create!(
      parent: subprogram,
      node_type: "activity",
      code: "01.02",
      display_number: "1.2",
      name: "Единственное мероприятие с кодом 01.02"
    )
    item = @change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Неуказанное направление",
      new_amount_rub: "34386810.02",
      delta_rub: "34386810.02",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "UNASSIGNED_RESIDUAL",
        "match_status" => "UNASSIGNED_RESIDUAL",
        "group_key" => "UNASSIGNED_RESIDUAL::106010200000000::170",
        "parent_activity_code" => "106010200000000",
        "object_code" => "0000000000.0000000000",
        "row_number" => 170
      },
      confidence: "0.0"
    )

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!

    assert_equal "resolved", item.reload.agent_resolution_status
    assert_equal "confirmed", item.status
    assert_equal "residual_parent_code", item.agent_resolution_evidence["resolution_pass"]
  end

  test "resolves coded Excel new objects under activity-like DOCX object rows" do
    @version.program_nodes.create!(
      node_type: "object",
      code: "03.04",
      display_number: "3.4",
      name: "Мероприятие 03.04 Строительство объектов водоснабжения",
      metadata: { "finance_table_index" => 1 }
    )
    item = @change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Новый ВЗУ",
      new_amount_rub: "100000.00",
      delta_rub: "100000.00",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "GROUPED_OBJECT",
        "match_status" => "MISSING_IN_DOCX",
        "group_key" => "101030400000000::100001::новый взу",
        "parent_activity_code" => "101030400000000",
        "object_code" => "100001",
        "row_number" => 20
      },
      confidence: "0.0"
    )

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!

    assert_equal "resolved", item.reload.agent_resolution_status
    assert_equal "confirmed", item.status
    assert_equal "new_object_parent_code", item.agent_resolution_evidence["resolution_pass"]
  end

  test "falls back to matching main activity when coded activity is absent" do
    @version.program_nodes.create!(
      node_type: "object",
      code: "03",
      display_number: "3",
      name: "Основное мероприятие 03 Строительство объектов водоснабжения",
      metadata: { "finance_table_index" => 1 }
    )
    item = @change_set.change_items.create!(
      change_type: "new_object",
      status: "draft",
      field_name: "object",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      new_value: "Новый ВЗУ",
      new_amount_rub: "100000.00",
      delta_rub: "100000.00",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "GROUPED_OBJECT",
        "match_status" => "MISSING_IN_DOCX",
        "group_key" => "101030400000000::100001::новый взу",
        "parent_activity_code" => "101030400000000",
        "object_code" => "100001",
        "row_number" => 20
      },
      confidence: "0.0"
    )

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!

    assert_equal "resolved", item.reload.agent_resolution_status
    assert_equal "confirmed", item.status
  end

  test "blocks amount updates mapped to non-financial result nodes" do
    result_node = @version.program_nodes.create!(
      node_type: "result",
      name: "Приобретено коммунальной техники",
      normalized_name: "приобретено коммунальной техники"
    )
    item = @change_set.change_items.create!(
      program_node: result_node,
      change_type: "amount_update",
      status: "draft",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "0",
      new_amount_rub: "7388096.53",
      delta_rub: "7388096.53",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "UNASSIGNED_RESIDUAL",
        "match_status" => "MATCH_RESIDUAL_PARENT",
        "object_code" => "0000000000.0000000000"
      },
      confidence: "0.6"
    )

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!

    assert_equal "needs_clarification", item.reload.agent_resolution_status
    assert_match(/финансов/i, item.agent_resolution_reason)
  end

  test "blocks amount updates mapped to summary total rows" do
    total_node = @version.program_nodes.create!(
      node_type: "object",
      name: "Итого по подпрограмме",
      normalized_name: "итого по подпрограмме",
      display_number: "Итого по подпрограмме"
    )
    item = @change_set.change_items.create!(
      program_node: total_node,
      change_type: "amount_update",
      status: "draft",
      field_name: "amount_rub",
      year: 2026,
      source_type: "LOCAL_BUDGET",
      old_amount_rub: "0",
      new_amount_rub: "7388096.53",
      delta_rub: "7388096.53",
      source_reference: {
        "document_type" => "xlsx_finance",
        "group_status" => "UNASSIGNED_RESIDUAL",
        "match_status" => "MATCH_RESIDUAL_PARENT"
      },
      confidence: "0.6"
    )

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!

    assert_equal "needs_clarification", item.reload.agent_resolution_status
    assert_match(/финансов/i, item.agent_resolution_reason)
  end
end
