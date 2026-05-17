class AgentToolCall < ApplicationRecord
  belongs_to :agent_conversation
  belongs_to :agent_message, optional: true

  validates :tool_name, presence: true
end
