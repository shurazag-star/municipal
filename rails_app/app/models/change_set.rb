class ChangeSet < ApplicationRecord
  belongs_to :program_version
  belongs_to :source_document, optional: true
  belongs_to :analysis_session, optional: true
  belongs_to :created_by, class_name: "User"
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :target_program_version, class_name: "ProgramVersion", optional: true

  has_many :change_items, dependent: :destroy
  has_many :manual_change_instructions, dependent: :nullify
  has_one_attached :generated_docx_attachment
  has_one_attached :change_report_attachment

  enum :status, {
    draft: "draft",
    pending_confirmation: "pending_confirmation",
    ready_for_approval: "ready_for_approval",
    approved: "approved",
    applied: "applied",
    export_failed: "export_failed",
    needs_manual_review: "needs_manual_review",
    rejected: "rejected"
  }, default: "draft"

  def export_ready?
    applied? &&
      generated_docx_attachment.attached? &&
      change_report_attachment.attached? &&
      export_summary.dig("post_export_validation", "status").in?(%w[valid valid_with_warnings]) &&
      export_summary.dig("agent_self_check", "status") == "passed" &&
      export_summary.dig("independent_verifier", "status").in?([nil, "passed"]) &&
      export_summary["manual_insert_required_count"].to_i.zero?
  end

  def refresh_summary!
    item_count = change_items.count
    unresolved_count = change_items.where(agent_resolution_status: "needs_clarification").count
    excluded_count = change_items.where(agent_resolution_status: "excluded").count
    resolved_count = change_items.where(agent_resolution_status: "resolved").count
    text =
      if item_count.zero?
        "Анализ выполнен, изменений сумм не найдено"
      elsif unresolved_count.positive?
        "Найдено изменений: #{item_count}. Агент сопоставил #{resolved_count}, исключил #{excluded_count}, нужно уточнение по #{unresolved_count}."
      else
        "Найдено изменений: #{item_count}. Агент сопоставил применимые строки и может формировать новую редакцию."
      end
    update!(summary: text)
  end
end
