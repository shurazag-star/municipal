class MunicipalTenantProvisioner
  class Error < StandardError; end

  Result = Struct.new(:organization, :admin, :employee, keyword_init: true)

  TENANT_SETTING_KEYS = %w[
    default_source_mode
    source_priority_policy
    openrouter_provider
    openrouter_models
    openrouter_models_loaded_at
    openrouter_model_primary
    openrouter_model_fast
    money_tolerance_rub
    excel_target_coverage_threshold
    excel_absence_policy
    excel_target_zero_absent
  ].freeze

  AGENT_SETTING_ATTRIBUTES = %w[
    system_prompt
    primary_model
    fast_model
    temperature
    match_confidence_threshold
    money_tolerance_rub
    use_knowledge_base
    use_chat_history
    auto_apply_exact_matches
    show_technical_statuses
  ].freeze

  def self.provision!(...)
    new(...).provision!
  end

  def initialize(
    key:,
    name:,
    municipality_name:,
    region_name: "Московская область",
    organization: nil,
    template_organization: nil,
    admin_email: nil,
    admin_password: nil,
    employee_email: nil,
    employee_password: nil,
    settings_overrides: {},
    require_passwords: Rails.env.production?
  )
    @key = normalize_key(key)
    @name = name
    @municipality_name = municipality_name
    @region_name = region_name
    @organization = organization
    @template_organization = template_organization
    @admin_email = admin_email.to_s.strip.presence
    @admin_password = admin_password.to_s.presence
    @employee_email = employee_email.to_s.strip.presence
    @employee_password = employee_password.to_s.presence
    @settings_overrides = settings_overrides.to_h.stringify_keys
    @require_passwords = require_passwords
  end

  def provision!
    organization = find_or_build_organization!

    ActiveRecord::Base.transaction do
      organization.update!(
        name: @name,
        municipality_name: @municipality_name,
        region_name: @region_name,
        settings: tenant_settings_for(organization)
      )
      ensure_agent_setting!(organization)
      admin = ensure_user!(organization, @admin_email, @admin_password, "admin")
      employee = ensure_user!(organization, @employee_email, @employee_password, "user")
      Result.new(organization: organization.reload, admin: admin, employee: employee)
    end
  end

  private

  def normalize_key(value)
    key = value.to_s.strip.downcase
    raise Error, "tenant key is required" if key.blank?

    key
  end

  def find_or_build_organization!
    return @organization if @organization.present?

    Organization.where("settings ->> 'tenant_key' = ?", @key).first ||
      Organization.find_by(name: @name) ||
      Organization.new
  end

  def tenant_settings_for(organization)
    template_settings
      .merge("default_source_mode" => "auto")
      .merge(organization.settings.to_h)
      .merge(@settings_overrides)
      .merge("tenant_key" => @key)
      .tap do |settings|
        settings["default_source_mode"] = SourceModeResolver.normalize(settings["default_source_mode"]) || "auto"
      end
  end

  def template_settings
    return {} unless @template_organization

    @template_organization.settings.to_h.slice(*TENANT_SETTING_KEYS)
  end

  def ensure_agent_setting!(organization)
    return organization.agent_setting if organization.agent_setting.present?

    attrs = template_agent_setting_attributes
    if attrs.present?
      organization.create_agent_setting!(attrs)
    else
      AgentSetting.for_organization!(organization)
    end
  end

  def template_agent_setting_attributes
    setting = @template_organization&.agent_setting
    return {} unless setting

    setting.attributes.slice(*AGENT_SETTING_ATTRIBUTES)
  end

  def ensure_user!(organization, email, password, role)
    return nil if email.blank?

    user = User.find_or_initialize_by(email: email)
    if user.persisted? && user.organization_id.present? && user.organization_id != organization.id
      raise Error, "Пользователь #{email} уже привязан к другой организации"
    end

    if user.new_record? && password.blank? && @require_passwords
      raise Error, "Пароль для #{email} обязателен"
    end

    user.password = password if password.present?
    user.organization = organization
    user.role = role
    user.save!
    user
  end
end
