class ManualChangeInstruction < ApplicationRecord
  belongs_to :organization
  belongs_to :user, optional: true
  belongs_to :agent_conversation, optional: true
  belongs_to :change_set, optional: true
  belongs_to :program_node, optional: true

  enum :clarification_status, {
    complete: "complete",
    needs_clarification: "needs_clarification",
    rejected: "rejected"
  }, default: "needs_clarification"

  validates :source_mode, presence: true
  validates :operation, presence: true
end
