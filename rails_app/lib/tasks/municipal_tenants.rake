namespace :municipal do
  def tenant_bool_env(key)
    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end

  def tenant_org_from_env(key)
    id = ENV[key].to_s.strip
    return nil if id.blank?

    Organization.find(id)
  end

  def tenant_template_organization
    Organization.where("settings ->> 'tenant_key' = ?", "lyubertsy").first ||
      Organization.where("name ILIKE ?", "%Любер%").first
  end

  def tenant_secret(name, development_default = nil)
    value = ENV[name].to_s.presence
    return value if value.present?
    return development_default unless Rails.env.production?

    raise "#{name} is required in production"
  end

  def tenant_email(name, development_default = nil)
    value = ENV[name].to_s.strip.presence
    return value if value.present?
    return development_default unless Rails.env.production?

    raise "#{name} is required in production"
  end

  def print_tenant_result(label, result)
    emails = result.organization.users.order(:role, :email).pluck(:role, :email).map { |role, email| "#{role}:#{email}" }
    puts "#{label}: organization_id=#{result.organization.id}, tenant_key=#{result.organization.settings["tenant_key"]}, users=#{emails.join(", ")}"
  end

  desc "Provision or mark the Lyubertsy municipal tenant without touching uploaded documents"
  task provision_lyubertsy: :environment do
    result = MunicipalTenantProvisioner.provision!(
      key: "lyubertsy",
      name: ENV.fetch("LYUBERTSY_ORG_NAME", "Городской округ Люберцы"),
      municipality_name: ENV.fetch("LYUBERTSY_MUNICIPALITY_NAME", "Городского округа Люберцы"),
      region_name: ENV.fetch("LYUBERTSY_REGION_NAME", "Московская область"),
      organization: tenant_org_from_env("LYUBERTSY_ORGANIZATION_ID"),
      admin_email: ENV["LYUBERTSY_ADMIN_EMAIL"].presence || ENV["ADMIN_EMAIL"].presence,
      admin_password: ENV["LYUBERTSY_ADMIN_PASSWORD"].presence || ENV["ADMIN_PASSWORD"].presence,
      employee_email: ENV["LYUBERTSY_EMPLOYEE_EMAIL"].presence || ENV["EMPLOYEE_EMAIL"].presence,
      employee_password: ENV["LYUBERTSY_EMPLOYEE_PASSWORD"].presence || ENV["EMPLOYEE_PASSWORD"].presence,
      settings_overrides: {
        "openrouter_model_primary" => ENV["OPENROUTER_MODEL_PRIMARY"],
        "openrouter_model_fast" => ENV["OPENROUTER_MODEL_FAST"],
        "money_tolerance_rub" => ENV["MONEY_TOLERANCE_RUB"]
      }.compact
    )
    print_tenant_result("Lyubertsy tenant", result)
  end

  desc "Provision the Shatura municipal tenant cloned from Lyubertsy agent settings"
  task provision_shatura: :environment do
    result = MunicipalTenantProvisioner.provision!(
      key: "shatura",
      name: ENV.fetch("SHATURA_ORG_NAME", "Муниципальный округ Шатура"),
      municipality_name: ENV.fetch("SHATURA_MUNICIPALITY_NAME", "Муниципального округа Шатура"),
      region_name: ENV.fetch("SHATURA_REGION_NAME", "Московская область"),
      organization: tenant_org_from_env("SHATURA_ORGANIZATION_ID"),
      template_organization: tenant_template_organization,
      admin_email: tenant_email("SHATURA_ADMIN_EMAIL", "admin-shatura@example.com"),
      admin_password: tenant_secret("SHATURA_ADMIN_PASSWORD", "password123"),
      employee_email: tenant_email("SHATURA_EMPLOYEE_EMAIL", "employee-shatura@example.com"),
      employee_password: tenant_secret("SHATURA_EMPLOYEE_PASSWORD", "1111")
    )
    print_tenant_result("Shatura tenant", result)
  end

  desc "Provision Lyubertsy and, when requested, Shatura municipal tenants"
  task provision_tenants: :environment do
    Rake::Task["municipal:provision_lyubertsy"].invoke
    if tenant_bool_env("PROVISION_SHATURA") || ENV["SHATURA_EMPLOYEE_EMAIL"].present? || ENV["SHATURA_ADMIN_EMAIL"].present?
      Rake::Task["municipal:provision_shatura"].invoke
    else
      puts "Shatura tenant skipped. Set PROVISION_SHATURA=true or SHATURA_* credentials to create it."
    end
  end
end
