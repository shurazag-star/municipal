class GeneratedVersionApprovalService
  class Error < StandardError; end

  def initialize(organization:, user:)
    @organization = organization
    @user = user
  end

  def approve_latest!
    change_set = latest_validated_draft
    raise Error, "Нет проверенной новой редакции для утверждения" unless change_set

    approve_change_set!(change_set)
  end

  def approve_change_set!(change_set)
    restore_rejected_change_set!(change_set) if recoverable_rejected_change_set?(change_set)
    raise Error, "Новая редакция не прошла проверки" unless change_set&.export_ready?

    target_version = change_set.target_program_version
    raise Error, "У проекта изменений нет сформированной версии программы" unless target_version

    program = target_version.municipal_program
    raise Error, "Версия относится к другой организации" unless program.organization_id == @organization.id

    ActiveRecord::Base.transaction do
      old_active = program.current_version
      old_active&.update!(status: "archived") if old_active && old_active.id != target_version.id
      target_version.update!(status: "approved_active")
      program.update!(current_version: target_version)
      AuditLog.record!(
        @user,
        @organization,
        "generated_version.approved",
        change_set,
        old_program_version_id: old_active&.id,
        active_program_version_id: target_version.id
      )
    end

    {
      "status" => "approved",
      "change_project_id" => change_set.id,
      "active_program_version_id" => target_version.id
    }
  end

  def reject_change_set!(change_set)
    target_version = change_set&.target_program_version
    raise Error, "Черновик новой редакции не найден" unless target_version

    target_version.update!(status: "generated_rejected")
    change_set.update!(status: "rejected")
    AuditLog.record!(@user, @organization, "generated_version.rejected", change_set, target_program_version_id: target_version.id)
    { "status" => "rejected", "change_project_id" => change_set.id, "target_program_version_id" => target_version.id }
  end

  private

  def recoverable_rejected_change_set?(change_set)
    return false unless change_set&.rejected?

    target_version = change_set.target_program_version
    target_version&.generated_rejected_status? &&
      change_set.generated_docx_attachment.attached? &&
      change_set.change_report_attachment.attached? &&
      change_set.export_summary.dig("post_export_validation", "status").in?(%w[valid valid_with_warnings]) &&
      change_set.export_summary.dig("agent_self_check", "status") == "passed" &&
      change_set.export_summary.dig("independent_verifier", "status").in?([nil, "passed"]) &&
      change_set.export_summary["manual_insert_required_count"].to_i.zero?
  end

  def restore_rejected_change_set!(change_set)
    change_set.target_program_version.update!(status: "generated_validated")
    change_set.update!(status: "applied")
    AuditLog.record!(
      @user,
      @organization,
      "generated_version.restored_for_approval",
      change_set,
      target_program_version_id: change_set.target_program_version_id
    )
  end

  def latest_validated_draft
    ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: @organization.id })
      .where(status: "applied")
      .order(updated_at: :desc)
      .detect { |change_set| change_set.export_ready? && change_set.target_program_version&.generated_validated_status? }
  end
end
