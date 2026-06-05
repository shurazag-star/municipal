require "test_helper"

class DocxPatchPlanBuilderTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "patch-plan@example.com")
    @program = MunicipalProgram.create!(
      organization: @user.organization,
      name: "Развитие инженерной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2028
    )
    @version = @program.program_versions.create!(
      created_by: @user,
      version_number: 2,
      status: "changed",
      import_summary: {
        "passport_source_cell_coordinates" => {
          "2026::LOCAL_BUDGET" => {
            "table_index" => 0,
            "row_index" => 1,
            "cell_index" => 2,
            "raw_value" => "150,00",
            "unit_in_document" => "thousand_rub"
          },
          "2027::LOCAL_BUDGET" => {
            "table_index" => 0,
            "row_index" => 1,
            "cell_index" => 3,
            "raw_value" => "200,00",
            "unit_in_document" => "thousand_rub"
          },
          "2026::MOSCOW_OBLAST_BUDGET" => {
            "table_index" => 0,
            "row_index" => 3,
            "cell_index" => 2,
            "raw_value" => "100,00",
            "unit_in_document" => "thousand_rub"
          }
        },
        "passport_source_total_cell_coordinates" => {
          "LOCAL_BUDGET" => {
            "table_index" => 0,
            "row_index" => 1,
            "cell_index" => 1,
            "raw_value" => "300,00",
            "unit_in_document" => "thousand_rub"
          }
        },
        "passport_grand_total_cell_coordinate" => {
          "table_index" => 0,
          "row_index" => 2,
          "cell_index" => 1,
          "raw_value" => "300,00",
          "unit_in_document" => "thousand_rub"
        }
      }
    )
    @root = @version.program_nodes.create!(node_type: "program", name: "Программа")
    @root.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "150000.00")
    @root.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "200000.00")
    @root.funding_lines.create!(year: 2026, source_type: "REGIONAL_BUDGET", amount_rub: "125000.00")
  end

  test "patches passport total column cells after recalculation" do
    updates = DocxPatchPlanBuilder.new(
      target_program_version: @version,
      amount_items: [],
      new_object_result: {},
      node_map: {}
    ).cell_updates

    source_total = updates.detect { |update| update["reason"] == "passport_source_total_column" }
    grand_total = updates.detect { |update| update["reason"] == "passport_grand_total_column" }

    assert_equal BigDecimal("350000.00"), BigDecimal(source_total.fetch("amount_rub"))
    assert_equal BigDecimal("475000.00"), BigDecimal(grand_total.fetch("amount_rub"))
  end

  test "patches canonical regional source into legacy Moscow oblast passport cells" do
    updates = DocxPatchPlanBuilder.new(
      target_program_version: @version,
      amount_items: [],
      new_object_result: {},
      node_map: {}
    ).cell_updates

    regional = updates.detect do |update|
      update["reason"] == "passport_source_year" &&
        update["row_index"] == 3 &&
        update["cell_index"] == 2
    end

    assert_equal BigDecimal("125000.00"), BigDecimal(regional.fetch("amount_rub"))
  end

  test "infers missing passport total column coordinates from year coordinates" do
    @version.update!(
      import_summary: @version.import_summary.except(
        "passport_source_total_cell_coordinates",
        "passport_grand_total_cell_coordinate"
      ).merge(
        "passport_total_cell_coordinates" => {
          "2026" => {
            "table_index" => 0,
            "row_index" => 4,
            "cell_index" => 2,
            "raw_value" => "275,00",
            "unit_in_document" => "thousand_rub"
          }
        }
      )
    )

    updates = DocxPatchPlanBuilder.new(
      target_program_version: @version,
      amount_items: [],
      new_object_result: {},
      node_map: {}
    ).cell_updates

    local_total = updates.detect { |update| update["reason"] == "passport_source_total_column" && update["row_index"] == 1 }
    grand_total = updates.detect { |update| update["reason"] == "passport_grand_total_column" }

    assert_equal 1, local_total["cell_index"]
    assert_equal BigDecimal("350000.00"), BigDecimal(local_total.fetch("amount_rub"))
    assert_equal 1, grand_total["cell_index"]
    assert_equal BigDecimal("475000.00"), BigDecimal(grand_total.fetch("amount_rub"))
  end

  test "passport total columns sum displayed rounded year values" do
    @root.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").update!(amount_rub: "150004.09")
    @root.funding_lines.find_by!(year: 2027, source_type: "LOCAL_BUDGET").update!(amount_rub: "200003.88")

    updates = DocxPatchPlanBuilder.new(
      target_program_version: @version,
      amount_items: [],
      new_object_result: {},
      node_map: {}
    ).cell_updates

    source_total = updates.detect { |update| update["reason"] == "passport_source_total_column" }
    grand_total = updates.detect { |update| update["reason"] == "passport_grand_total_column" }

    assert_equal BigDecimal("350000.00"), BigDecimal(source_total.fetch("amount_rub"))
    assert_equal BigDecimal("475000.00"), BigDecimal(grand_total.fetch("amount_rub"))
  end

  test "finance total columns sum displayed rounded year values" do
    node = @version.program_nodes.create!(
      node_type: "activity",
      name: "Мероприятие",
      source_table_index: 2,
      source_row_index: 10,
      metadata: {
        "docx_year_cell_indexes" => { "2026" => 5, "2027" => 6 },
        "docx_total_cell_index" => 4,
        "docx_unit_in_document" => "thousand_rub"
      }
    )
    node.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100004.09",
      metadata: {
        "source_table_index" => 2,
        "source_row_index" => 11,
        "source_cell_index" => 5,
        "total_cell_index" => 4,
        "unit_in_document" => "thousand_rub"
      }
    )
    node.funding_lines.create!(
      year: 2027,
      source_type: "LOCAL_BUDGET",
      amount_rub: "200003.88",
      metadata: {
        "source_table_index" => 2,
        "source_row_index" => 11,
        "source_cell_index" => 6,
        "total_cell_index" => 4,
        "unit_in_document" => "thousand_rub"
      }
    )
    item = ChangeItem.new(program_node_id: node.id)

    updates = DocxPatchPlanBuilder.new(
      target_program_version: @version,
      amount_items: [item],
      new_object_result: {},
      node_map: { node.id => node }
    ).cell_updates

    node_total = updates.detect { |update| update["reason"] == "node_total_column" }
    line_total = updates.detect { |update| update["reason"] == "funding_line_total_column" }

    assert_equal BigDecimal("300000.00"), BigDecimal(node_total.fetch("amount_rub"))
    assert_equal BigDecimal("300000.00"), BigDecimal(line_total.fetch("amount_rub"))
  end

  test "infers missing funding year cell from adjacent years in the same row" do
    node = @version.program_nodes.create!(
      node_type: "object",
      name: "Объект",
      source_table_index: 2,
      source_row_index: 10
    )
    node.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100000.00",
      metadata: { "source_table_index" => 2, "source_row_index" => 10, "source_cell_index" => 4 }
    )
    node.funding_lines.create!(
      year: 2027,
      source_type: "LOCAL_BUDGET",
      amount_rub: "200000.00",
      metadata: { "source_table_index" => 2, "source_row_index" => 10, "source_cell_index" => 5 }
    )
    node.funding_lines.create!(
      year: 2028,
      source_type: "LOCAL_BUDGET",
      amount_rub: "300000.00",
      metadata: { "source_table_index" => 2, "source_row_index" => 10 }
    )
    item = ChangeItem.new(program_node_id: node.id)

    updates = DocxPatchPlanBuilder.new(
      target_program_version: @version,
      amount_items: [item],
      new_object_result: {},
      node_map: { node.id => node }
    ).cell_updates

    inferred = updates.detect do |update|
      update["reason"] == "funding_line_year" &&
        update["table_index"] == 2 &&
        update["row_index"] == 10 &&
        update["cell_index"] == 6
    end

    assert_equal BigDecimal("300000.00"), BigDecimal(inferred.fetch("amount_rub"))
  end

  test "plans execution period text update from nonzero funding years" do
    node = @version.program_nodes.create!(
      node_type: "object",
      name: "Объект",
      display_number: "2.1.1",
      source_table_index: 3,
      source_row_index: 10,
      execution_period: "2026-2028",
      metadata: { "source" => "finance_table" }
    )
    line = node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "0.00")
    node.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "100000.00")
    item = ChangeItem.new(
      program_node_id: line.program_node_id,
      source_reference: { "amount_mode" => "zeroing", "target_model_absent_in_excel" => true }
    )

    updates = DocxPatchPlanBuilder.new(
      target_program_version: @version,
      amount_items: [item],
      new_object_result: {},
      node_map: { node.id => node }
    ).text_updates

    update = updates.detect { |payload| payload["reason"] == "execution_period" }
    assert_equal 3, update["table_index"]
    assert_equal 10, update["row_index"]
    assert_equal 2, update["cell_index"]
    assert_equal "2027", update["text"]
  end
end
