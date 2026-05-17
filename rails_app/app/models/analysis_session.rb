class AnalysisSession < ApplicationRecord
  belongs_to :organization
  belongs_to :user
  belongs_to :program_version

  has_many :change_sets, dependent: :nullify
  has_many :agent_match_decisions, dependent: :nullify

  enum :status, {
    draft: "draft",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, default: "draft"

  def selected_source_document_ids
    Array(super).map(&:to_i)
  end

  def effective_source_mode
    requested = source_mode.presence
    requested = summary&.fetch("source_mode", nil) if requested.blank? || requested == "auto"
    SourceModeResolver.normalize(requested) || "auto"
  end
end
