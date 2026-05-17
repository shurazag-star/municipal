class AgentSettingsController < ApplicationController
  before_action :require_admin!

  def show
    load_settings_state
  end

  def update
    setting = AgentSetting.for_organization!(current_organization)
    setting.update!(agent_setting_params)
    sync_organization_openrouter_settings(setting)
    AuditLog.record!(current_user, current_organization, "agent_settings.updated", setting)
    redirect_to agent_settings_path, notice: "Настройки агента сохранены"
  end

  private

  def load_settings_state
    @agent_setting = AgentSetting.for_organization!(current_organization)
    @models = Array(current_organization.settings["openrouter_models"])
    selected = [
      @agent_setting.primary_model,
      @agent_setting.fast_model,
      OpenRouterModelsClient::DEFAULT_PRIMARY_MODEL_ID,
      OpenRouterModelsClient::DEFAULT_FAST_MODEL_ID
    ].compact.uniq
    @model_options = @models.map { |model| ["#{model["name"]} — #{model["id"]}", model["id"]] }
    existing_ids = @model_options.map(&:last)
    selected.each do |model_id|
      @model_options << [model_id, model_id] unless existing_ids.include?(model_id)
    end
  end

  def agent_setting_params
    params.require(:agent_setting).permit(
      :system_prompt,
      :primary_model,
      :fast_model,
      :temperature,
      :match_confidence_threshold,
      :money_tolerance_rub,
      :use_knowledge_base,
      :use_chat_history,
      :auto_apply_exact_matches,
      :show_technical_statuses
    )
  end

  def sync_organization_openrouter_settings(setting)
    settings = current_organization.settings.deep_dup
    settings["openrouter_model_primary"] = setting.primary_model
    settings["openrouter_model_fast"] = setting.fast_model
    settings["money_tolerance_rub"] = setting.money_tolerance_rub.to_s("F")
    current_organization.update!(settings: settings)
  end
end
