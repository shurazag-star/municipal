require "test_helper"

class SemanticCandidateBuilderTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "semantic-candidates@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @subprogram = @version.program_nodes.create!(node_type: "subprogram", display_number: "1", name: "Инженерная инфраструктура")
    @activity = @version.program_nodes.create!(parent: @subprogram, node_type: "activity", code: "01.02", display_number: "1.2", name: "Водоснабжение")
    @target = @version.program_nodes.create!(parent: @activity, node_type: "object", display_number: "1.2.1", name: "Капитальный ремонт ВЗУ Черусти", normalized_name: "капитальный ремонт взу черусти")
    @other = @version.program_nodes.create!(node_type: "object", display_number: "9.1", name: "Котельная Рошаль", normalized_name: "котельная рошаль")
  end

  test "returns compact ranked candidate snapshots" do
    candidates = SemanticCandidateBuilder.new(program_version: @version).build(
      group: {
        "object_name" => "Ремонт водозаборного узла Черусти",
        "parent_activity_code" => "1010102"
      }
    )

    assert_equal @target.id, candidates.first["program_node_id"]
    assert candidates.first["path"].any? { |part| part.include?("Водоснабжение") }
    assert_includes candidates.first.keys, "similarity_score"
    assert_not_includes candidates.map { |candidate| candidate["program_node_id"] }, @other.id
  end
end
