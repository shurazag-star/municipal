class MatchCandidate < ApplicationRecord
  belongs_to :program_version
  belongs_to :source_document
  belongs_to :program_node, optional: true
  belongs_to :excel_row, optional: true

  has_many :agent_match_decisions, dependent: :nullify
end
