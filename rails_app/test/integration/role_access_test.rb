require "test_helper"

class RoleAccessTest < ActionDispatch::IntegrationTest
  setup do
    @employee = create_isolated_user!(email: "employee-role-access@example.com", password: "1111", role: "user")
    @organization = @employee.organization
  end

  test "employee cannot open admin workbench routes directly" do
    login_as(@employee, "1111")

    get agent_settings_path
    assert_response :forbidden

    get source_documents_path
    assert_response :forbidden

    get programs_path
    assert_response :forbidden

    get change_sets_path
    assert_response :forbidden

    get knowledge_chunks_path
    assert_response :forbidden
  end

  test "employee cannot update agent settings directly" do
    setting = AgentSetting.for_organization!(@organization)
    login_as(@employee, "1111")

    assert_no_changes -> { setting.reload.system_prompt } do
      patch agent_settings_path, params: {
        agent_setting: {
          system_prompt: "Сотрудник не должен менять системный промпт"
        }
      }
    end

    assert_response :forbidden
  end

  test "employee workspace remains available" do
    login_as(@employee, "1111")

    get employee_workspace_path

    assert_response :success
    assert_select ".employee-chat-shell"
  end

  private

  def login_as(user, password)
    post session_path, params: { email: user.email, password: password }
  end
end
