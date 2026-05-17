class AgentMessage < ApplicationRecord
  belongs_to :agent_conversation
  belongs_to :user, optional: true

  has_many :agent_tool_calls, dependent: :nullify

  enum :role, {
    user: "user",
    assistant: "assistant",
    system: "system",
    tool: "tool"
  }

  validates :content, presence: true
end
