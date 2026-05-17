module Admin
  class OpenrouterSettingsController < ApplicationController
    before_action :require_admin!

    def show
      load_openrouter_state
    end

    def load_models
      models = openrouter_models_client.list_models
      settings = current_organization.settings.deep_dup
      settings["openrouter_provider"] = "openrouter"
      settings["openrouter_models"] = models
      settings["openrouter_models_loaded_at"] = Time.current.iso8601
      settings["openrouter_model_primary"] = OpenRouterModelsClient.default_primary_model_id(models)
      settings["openrouter_model_fast"] = OpenRouterModelsClient.default_fast_model_id(models)

      current_organization.update!(settings: settings)
      AgentSetting.for_organization!(current_organization).sync_openrouter_models_from_organization!
      AuditLog.record!(
        current_user,
        current_organization,
        "openrouter_settings.models_loaded",
        current_organization,
        { model_count: models.size, primary_model: settings["openrouter_model_primary"] }
      )

      redirect_to admin_openrouter_settings_path, notice: "Загружено моделей: #{models.size}"
    rescue OpenRouterModelsClient::Error => error
      redirect_to admin_openrouter_settings_path, alert: error.message
    end

    def update
      settings = current_organization.settings.deep_dup
      settings["openrouter_provider"] = "openrouter"
      settings["openrouter_model_primary"] = params[:openrouter_model_primary].presence || OpenRouterModelsClient::DEFAULT_PRIMARY_MODEL_ID
      settings["openrouter_model_fast"] = params[:openrouter_model_fast].presence || OpenRouterModelsClient::DEFAULT_FAST_MODEL_ID
      current_organization.update!(settings: settings)
      AgentSetting.for_organization!(current_organization).sync_openrouter_models_from_organization!
      AuditLog.record!(
        current_user,
        current_organization,
        "openrouter_settings.updated",
        current_organization,
        {
          primary_model: settings["openrouter_model_primary"],
          fast_model: settings["openrouter_model_fast"]
        }
      )
      redirect_to admin_openrouter_settings_path, notice: "Настройки OpenRouter сохранены"
    end

    private

    def load_openrouter_state
      @settings = current_organization.settings || {}
      @models = Array(@settings["openrouter_models"])
      @selected_model = @settings["openrouter_model_primary"].presence || ENV["OPENROUTER_MODEL_PRIMARY"].presence || OpenRouterModelsClient::DEFAULT_PRIMARY_MODEL_ID
      @selected_fast_model = @settings["openrouter_model_fast"].presence || ENV["OPENROUTER_MODEL_FAST"].presence || OpenRouterModelsClient::DEFAULT_FAST_MODEL_ID
      @openrouter_configured = OpenRouterModelsClient.configured?
      @models_loaded_at = @settings["openrouter_models_loaded_at"]
    end

    def openrouter_models_client
      configured_client = Rails.application.config.x.openrouter_models_client
      if configured_client.respond_to?(:list_models) && !configured_client.is_a?(ActiveSupport::OrderedOptions)
        return configured_client
      end

      OpenRouterModelsClient.new
    end
  end
end
