class ChangeItem < ApplicationRecord
  belongs_to :change_set
  belongs_to :program_node, optional: true

  has_many :agent_match_decisions, dependent: :nullify

  enum :change_type, {
    amount_update: "amount_update",
    new_object: "new_object",
    delete_object: "delete_object",
    name_update: "name_update",
    result_update: "result_update"
  }, default: "amount_update"

  enum :status, {
    draft: "draft",
    needs_confirmation: "needs_confirmation",
    confirmed: "confirmed",
    rejected: "rejected"
  }, default: "draft"

  enum :agent_resolution_status, {
    unresolved: "unresolved",
    resolved: "resolved",
    excluded: "excluded",
    needs_clarification: "needs_clarification"
  }, default: "unresolved", prefix: :agent_resolution

  scope :active_for_application, -> { where.not(status: "rejected").where.not(agent_resolution_status: "excluded") }
end
