require "test_helper"

class AgentSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_isolated_user!(email: "settings@example.com")
    @organization = @user.organization
    @organization.update!(
      settings: {
        "openrouter_models" => [
          { "id" => "deepseek/deepseek-v4-pro", "name" => "DeepSeek: DeepSeek V4 Pro" },
          { "id" => "deepseek/deepseek-v4-flash", "name" => "DeepSeek: DeepSeek V4 Flash" }
        ],
        "openrouter_model_primary" => "deepseek/deepseek-v4-pro",
        "openrouter_model_fast" => "deepseek/deepseek-v4-flash"
      }
    )
    post session_path, params: { email: @user.email, password: "password123" }
  end

  test "agent settings page saves prompt model and policy fields" do
    get agent_settings_path

    assert_response :success
    assert_select "h1", "Настройка агента"
    assert_select "textarea[name='agent_setting[system_prompt]']"
    assert_select "select[name='agent_setting[primary_model]'] option[value='deepseek/deepseek-v4-pro']"

    patch agent_settings_path, params: {
      agent_setting: {
        system_prompt: "Работай только через инструменты и проси подтверждение.",
        primary_model: "deepseek/deepseek-v4-pro",
        fast_model: "deepseek/deepseek-v4-flash",
        temperature: "0.20",
        match_confidence_threshold: "0.9500",
        money_tolerance_rub: "20.50",
        use_knowledge_base: "0",
        use_chat_history: "1",
        auto_apply_exact_matches: "1",
        show_technical_statuses: "0"
      }
    }

    assert_redirected_to agent_settings_path
    setting = @organization.reload.agent_setting
    assert_equal "Работай только через инструменты и проси подтверждение.", setting.system_prompt
    assert_equal "deepseek/deepseek-v4-pro", setting.primary_model
    assert_equal "deepseek/deepseek-v4-flash", setting.fast_model
    assert_equal BigDecimal("0.20"), setting.temperature
    assert_equal BigDecimal("0.9500"), setting.match_confidence_threshold
    assert_equal BigDecimal("20.50"), setting.money_tolerance_rub
    assert_not setting.use_knowledge_base
    assert setting.use_chat_history
    assert setting.auto_apply_exact_matches
    assert_not setting.show_technical_statuses
  end

  test "default prompt describes autonomous Russian municipal agent workflow" do
    setting = AgentSetting.for_organization!(@organization)

    assert_includes setting.system_prompt, "municipal program document agent"
    assert_includes setting.system_prompt, "always communicate with the user in Russian"
    assert_includes setting.system_prompt, "Manual user instructions in chat"
    assert_includes setting.system_prompt, "manual_instruction"
    assert_includes setting.system_prompt, "When a new DOCX is generated, it is a draft version until the user approves it"
    assert_includes setting.system_prompt, "Procedure/regulation PDF"
    assert_no_match(/требуй подтверждения/i, setting.system_prompt)
  end
end
