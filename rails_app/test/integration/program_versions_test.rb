require "test_helper"

class ProgramVersionsTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_isolated_user!(email: "program-version-ui@example.com")
    @program = MunicipalProgram.create!(
      organization: @user.organization,
      name: "Развитие инженерной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @program.update!(current_version: @version)
    @version.program_nodes.create!(
      node_type: "object",
      display_number: "1.1.1",
      name: "ВЗУ Черусти",
      source_table_index: 6,
      source_row_index: 61
    )
    login_as(@user)
  end

  test "program version structure table has scroll and nowrap layout guards" do
    get program_version_path(@version)

    assert_response :success
    assert_select ".table-scroll .structure-table"
    assert_includes @response.body, ".table-scroll"
    assert_includes @response.body, "overflow-x: auto"
    assert_includes @response.body, ".structure-table .meta-col"
    assert_includes @response.body, "white-space: nowrap"
  end

  private

  def login_as(user)
    post session_path, params: { email: user.email, password: "password123" }
  end
end
