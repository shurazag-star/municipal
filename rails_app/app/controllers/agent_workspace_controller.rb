class AgentWorkspaceController < ApplicationController
  def show
    redirect_to employee_workspace_path and return if employee_user?

    @context = AgentContextBuilder.new(organization: current_organization, user: current_user).build
    @conversation = AgentConversation.active_for!(organization: current_organization, user: current_user)
    @conversation.update!(context_snapshot: @context)
    @messages = @conversation.agent_messages.where(role: %w[user assistant]).order(:created_at, :id)
    @last_tool_calls = @conversation.agent_tool_calls.order(created_at: :desc).limit(5)
    @agent_setting = AgentSetting.for_organization!(current_organization)
    @active_agent_task = @conversation.agent_tasks
      .where(status: %w[queued running])
      .order(updated_at: :desc)
      .first
  end
end
