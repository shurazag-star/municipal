class AgentConversationsController < ApplicationController
  def clear
    audience = employee_user? ? "employee" : "admin"
    conversation = AgentConversation.active_for!(organization: current_organization, user: current_user, audience: audience)
    conversation.reset_with_welcome!(audience: audience)
    redirect_to current_workspace_path, notice: "Чат очищен. Документы и проекты изменений сохранены."
  end
end
