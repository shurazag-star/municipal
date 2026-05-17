require "test_helper"

class ProgramTreePersisterTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "program-tree@example.com")
    @organization = @user.organization
    @document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "program.docx",
      status: "parsed",
      parsed_payload: parsed_payload
    )
  end

  test "persists parsed program nodes and funding lines with coordinates" do
    profile = DocumentProfileBuilder.new(source_document: @document).build!
    version = ProgramTreePersister.new(source_document: @document, user: @user).persist!

    assert_equal version, @organization.municipal_programs.first.current_version
    assert_equal "Развитие инженерной инфраструктуры", version.municipal_program.name
    assert_equal 3, version.program_nodes.count
    assert_equal 2, FundingLine.joins(:program_node).where(program_nodes: { program_version_id: version.id }).count

    object = version.program_nodes.find_by!(node_type: "object")
    assert_equal "ВЗУ Черусти", object.name
    assert_equal 2, object.source_table_index
    assert_equal 5, object.source_row_index
    assert_equal "object-1", object.metadata["stable_key"]

    line = object.funding_lines.find_by!(source_type: "REGIONAL_BUDGET")
    assert_equal BigDecimal("78330390.00"), line.amount_rub
    assert_equal @document, line.source_document
    assert_equal "2:6:5", line.source_row_ref
    assert_equal "78 330,39", line.metadata["raw_value"]
    assert_equal "thousand_rub", line.metadata["unit_in_document"]
    assert_equal 5, line.metadata["source_cell_index"]
    assert_equal 4, line.metadata["total_cell_index"]
    assert_equal "90 555,38", line.metadata["total_raw_value"]
    assert_equal({ "2026" => 5 }, line.metadata["year_cell_indexes"])
    assert_equal "1:2:5", version.import_summary.dig("passport_total_cell_coordinates", "2026", "coordinate_key")
    assert_equal profile.id, version.import_summary["municipal_document_profile_id"]
    assert_equal "active", version.import_summary["municipal_document_profile_status"]
  end

  test "replaces old tree on reimport" do
    version = ProgramTreePersister.new(source_document: @document, user: @user).persist!
    old_node_id = version.program_nodes.find_by!(node_type: "object").id
    @document.update!(
      parsed_payload: parsed_payload.deep_merge(
        "nodes" => [
          {
            "stable_key" => "program",
            "node_type" => "program",
            "name" => "Развитие инженерной инфраструктуры",
            "normalized_name" => "развитие инженерной инфраструктуры",
            "metadata" => {}
          }
        ],
        "funding_lines" => []
      )
    )

    ProgramTreePersister.new(source_document: @document, user: @user).persist!

    assert_not ProgramNode.exists?(old_node_id)
    assert_equal 1, version.reload.program_nodes.count
  end

  test "each uploaded docx creates a separate imported version tied to source document" do
    first_version = ProgramTreePersister.new(source_document: @document, user: @user).persist!
    second_document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "program-2.docx",
      status: "parsed",
      parsed_payload: parsed_payload.deep_merge(
        "program" => { "name" => "Развитие инженерной инфраструктуры" },
        "nodes" => [
          {
            "stable_key" => "program",
            "node_type" => "program",
            "name" => "Развитие инженерной инфраструктуры",
            "normalized_name" => "развитие инженерной инфраструктуры",
            "metadata" => {}
          }
        ],
        "funding_lines" => []
      )
    )

    second_version = ProgramTreePersister.new(source_document: second_document, user: @user).persist!

    assert_not_equal first_version.id, second_version.id
    assert_equal 1, first_version.reload.version_number
    assert_equal 2, second_version.version_number
    assert_equal @document.id, first_version.import_summary["source_document_id"]
    assert_equal second_document.id, second_version.import_summary["source_document_id"]
    assert_equal second_version, second_version.municipal_program.current_version
    assert_equal 3, first_version.program_nodes.count
    assert_equal 1, second_version.program_nodes.count
  end

  private

  def parsed_payload
    {
      "program" => {
        "name" => "Развитие инженерной инфраструктуры",
        "period_start_year" => 2026,
        "period_end_year" => 2030
      },
      "passport_total_cell_coordinates" => {
        "2026" => {
          "table_index" => 1,
          "row_index" => 2,
          "cell_index" => 5,
          "raw_value" => "90 555,38",
          "unit_in_document" => "thousand_rub",
          "coordinate_key" => "1:2:5"
        }
      },
      "nodes" => [
        {
          "stable_key" => "program",
          "node_type" => "program",
          "name" => "Развитие инженерной инфраструктуры",
          "normalized_name" => "развитие инженерной инфраструктуры",
          "metadata" => {}
        },
        {
          "stable_key" => "sub-1",
          "node_type" => "subprogram",
          "parent_stable_key" => "program",
          "display_number" => "1",
          "name" => "Чистая вода",
          "normalized_name" => "чистая вода",
          "source_table_index" => 0,
          "source_row_index" => 4,
          "metadata" => {}
        },
        {
          "stable_key" => "object-1",
          "node_type" => "object",
          "parent_stable_key" => "sub-1",
          "display_number" => "1.1.1",
          "name" => "ВЗУ Черусти",
          "normalized_name" => "взу черусти",
          "execution_period" => "2026",
          "source_table_index" => 2,
          "source_row_index" => 5,
          "metadata" => {
            "docx_total_cell_index" => 4,
            "docx_year_cell_indexes" => { "2026" => 5 }
          }
        }
      ],
      "funding_lines" => [
        {
          "node_stable_key" => "object-1",
          "year" => 2026,
          "source_type" => "MOSCOW_OBLAST_BUDGET",
          "amount_rub" => "78330390.00",
          "unit_in_document" => "thousand_rub",
          "source_table_index" => 2,
          "source_row_index" => 6,
          "source_cell_index" => 5,
          "raw_value" => "78 330,39",
          "total_cell_index" => 4,
          "total_raw_value" => "90 555,38",
          "year_cell_indexes" => { "2026" => 5 }
        },
        {
          "node_stable_key" => "object-1",
          "year" => 2026,
          "source_type" => "LOCAL_BUDGET",
          "amount_rub" => "12224990.00",
          "unit_in_document" => "thousand_rub",
          "source_table_index" => 2,
          "source_row_index" => 7,
          "source_cell_index" => 5,
          "raw_value" => "12 224,99",
          "total_cell_index" => 4,
          "total_raw_value" => "90 555,38",
          "year_cell_indexes" => { "2026" => 5 }
        }
      ]
    }
  end
end
