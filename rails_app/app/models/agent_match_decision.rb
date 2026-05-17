class AgentMatchDecision < ApplicationRecord
  DECISION_TYPES = %w[
    existing_object
    new_object
    residual_to_parent
    aggregate_only
    ignore_not_finance
    needs_clarification
  ].freeze

  STATUSES = %w[
    created
    accepted
    rejected
    needs_clarification
    failed
  ].freeze

  belongs_to :organization
  belongs_to :user, optional: true
  belongs_to :analysis_session, optional: true
  belongs_to :source_document, optional: true
  belongs_to :match_candidate, optional: true
  belongs_to :change_item, optional: true
  belongs_to :selected_program_node, class_name: "ProgramNode", optional: true

  enum :decision_type, DECISION_TYPES.index_with(&:itself)
  enum :status, STATUSES.index_with(&:itself), prefix: true

  validates :decision_type, presence: true, inclusion: { in: DECISION_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
end
