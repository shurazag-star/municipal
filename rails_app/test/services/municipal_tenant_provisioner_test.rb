require "test_helper"

class MunicipalTenantProvisionerTest < ActiveSupport::TestCase
  setup do
    @lyubertsy = Organization.create!(
      name: "Городской округ Люберцы",
      municipality_name: "Городского округа Люберцы",
      region_name: "Московская область",
      settings: {
        "tenant_key" => "lyubertsy",
        "default_source_mode" => "auto",
        "openrouter_model_primary" => "lyubertsy-primary",
        "openrouter_model_fast" => "lyubertsy-fast",
        "excel_absence_policy" => "zero_if_program_total_requires"
      }
    )
    AgentSetting.for_organization!(@lyubertsy).update!(
      system_prompt: "Люберецкий агент: работай по утвержденному сценарию.",
      primary_model: "lyubertsy-primary",
      fast_model: "lyubertsy-fast",
      temperature: "0.15",
      match_confidence_threshold: "0.9100",
      money_tolerance_rub: "12.00",
      use_knowledge_base: true,
      use_chat_history: true,
      auto_apply_exact_matches: false,
      show_technical_statuses: false
    )
  end

  test "provisions Shatura as an isolated tenant cloned from Lyubertsy agent defaults" do
    result = MunicipalTenantProvisioner.provision!(
      key: "shatura",
      name: "Муниципальный округ Шатура",
      municipality_name: "Муниципального округа Шатура",
      region_name: "Московская область",
      template_organization: @lyubertsy,
      admin_email: "admin-shatura@example.com",
      admin_password: "admin-shatura-password",
      employee_email: "employee-shatura@example.com",
      employee_password: "employee-shatura-password"
    )

    shatura = result.organization
    assert_equal "shatura", shatura.settings["tenant_key"]
    assert_equal "auto", shatura.settings["default_source_mode"]
    assert_equal "lyubertsy-primary", shatura.settings["openrouter_model_primary"]
    assert_equal "zero_if_program_total_requires", shatura.settings["excel_absence_policy"]

    shatura_setting = AgentSetting.for_organization!(shatura)
    assert_equal "Люберецкий агент: работай по утвержденному сценарию.", shatura_setting.system_prompt
    assert_equal "lyubertsy-primary", shatura_setting.primary_model
    assert_equal BigDecimal("0.15"), shatura_setting.temperature
    assert_equal BigDecimal("0.9100"), shatura_setting.match_confidence_threshold
    assert_equal BigDecimal("12.00"), shatura_setting.money_tolerance_rub

    admin = shatura.users.find_by!(email: "admin-shatura@example.com")
    employee = shatura.users.find_by!(email: "employee-shatura@example.com")
    assert admin.admin?
    assert employee.user?
    assert admin.authenticate("admin-shatura-password")
    assert employee.authenticate("employee-shatura-password")
  end

  test "does not overwrite an existing tenant agent when provision is run again" do
    first = MunicipalTenantProvisioner.provision!(
      key: "shatura",
      name: "Муниципальный округ Шатура",
      municipality_name: "Муниципального округа Шатура",
      template_organization: @lyubertsy,
      employee_email: "employee-shatura-repeat@example.com",
      employee_password: "employee-password"
    ).organization
    AgentSetting.for_organization!(first).update!(system_prompt: "Шатурская отдельная инструкция")

    MunicipalTenantProvisioner.provision!(
      key: "shatura",
      name: "Муниципальный округ Шатура",
      municipality_name: "Муниципального округа Шатура",
      template_organization: @lyubertsy,
      employee_email: "employee-shatura-repeat@example.com"
    )

    assert_equal "Шатурская отдельная инструкция", AgentSetting.for_organization!(first.reload).system_prompt
  end

  test "refuses to silently move an existing user from another tenant" do
    User.create!(
      organization: @lyubertsy,
      email: "shared-login@example.com",
      password: "password123",
      role: "user"
    )

    error = assert_raises(MunicipalTenantProvisioner::Error) do
      MunicipalTenantProvisioner.provision!(
        key: "shatura",
        name: "Муниципальный округ Шатура",
        municipality_name: "Муниципального округа Шатура",
        employee_email: "shared-login@example.com",
        employee_password: "new-password"
      )
    end

    assert_includes error.message, "уже привязан к другой организации"
  end
end
