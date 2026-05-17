class AgentExplanationsController < ApplicationController
  before_action :require_admin!

  def create
    unless OpenRouterModelsClient.configured?
      redirect_to root_path, alert: "Добавьте OPENROUTER_API_KEY в .env и перезапустите web/sidekiq"
      return
    end

    AgentReportBuilder.new(organization: current_organization, user: current_user).explain!
    redirect_to root_path, notice: "ИИ-агент подготовил объяснение расхождений"
  rescue StandardError => error
    redirect_to root_path, alert: "ИИ-агент не смог подготовить объяснение: #{error.message}"
  end
end
