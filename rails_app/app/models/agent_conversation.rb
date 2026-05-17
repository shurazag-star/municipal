class AgentConversation < ApplicationRecord
  belongs_to :organization
  belongs_to :user

  has_many :agent_messages, dependent: :destroy
  has_many :agent_tool_calls, dependent: :destroy
  has_many :agent_tasks, dependent: :destroy
  has_many :manual_change_instructions, dependent: :nullify

  def self.active_for!(organization:, user:, audience: nil)
    conversation = where(organization: organization, user: user, status: "active").order(updated_at: :desc).first ||
      create!(organization: organization, user: user, title: "Рабочий чат", status: "active")
    conversation.ensure_welcome_message!(audience: audience)
    conversation
  end

  def ensure_welcome_message!(audience: nil)
    return if agent_messages.exists?

    context = AgentContextBuilder.new(organization: organization, user: user).build
    agent_messages.create!(
      role: "assistant",
      content: AgentOrchestrator.welcome_message(context, audience: audience),
      metadata: { kind: "welcome", audience: audience }.compact
    )
  end

  def reset_with_welcome!(audience: nil)
    agent_tasks.destroy_all
    agent_messages.destroy_all
    update!(cleared_at: Time.current, memory_summary: nil, working_state: {}, memory_updated_at: Time.current)
    ensure_welcome_message!(audience: audience)
  end
end
