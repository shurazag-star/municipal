class ChangeSetsController < ApplicationController
  before_action :require_admin!, only: %i[index create show confirm_item approve apply]

  def index
    @change_sets = scoped_change_sets.order(updated_at: :desc)
  end

  def create
    redirect_to root_path, alert: "Проект изменений создается только через анализ документов"
  end

  def show
    @change_set = scoped_change_sets.find_by(id: params[:id])
    return head :not_found unless @change_set

    @change_items = @change_set.change_items.includes(:program_node).order(:id)
  end

  def destroy
    change_set = scoped_change_sets.find(params[:id])
    version_number = change_set.target_program_version&.version_number
    change_set_id = change_set.id
    change_set.destroy!
    AuditLog.record!(
      current_user,
      current_organization,
      "change_set.deleted",
      nil,
      change_set_id: change_set_id,
      target_program_version_number: version_number
    )
    redirect_to current_workspace_path, notice: "Редакция удалена из списка."
  rescue ActiveRecord::InvalidForeignKey
    redirect_to current_workspace_path, alert: "Редакция сейчас связана с обработкой. Обновите страницу и повторите удаление."
  end

  def confirm_item
    change_set = scoped_change_sets.find(params[:id])
    item = change_set.change_items.find(params[:change_item_id])
    item.update!(
      user_confirmed: true,
      status: "confirmed",
      agent_resolution_status: "resolved",
      agent_resolution_reason: "Пользователь вручную отметил строку как разобранную."
    )
    change_set.refresh_summary!
    AuditLog.record!(current_user, current_organization, "change_item.confirmed", item)
    redirect_to change_set_path(change_set)
  end

  def approve
    change_set = scoped_change_sets.find(params[:id])
    if change_set.change_items.empty?
      redirect_to change_set_path(change_set), alert: "Нельзя подтвердить пустой проект изменений"
      return
    end
    change_set.update!(status: "approved", approved_by: current_user)
    AuditLog.record!(current_user, current_organization, "change_set.approved", change_set)
    redirect_to change_set_path(change_set)
  end

  def apply
    change_set = scoped_change_sets.find(params[:id])
    result = ChangeSetApplicationService.new(change_set: change_set, user: current_user).apply!
    AuditLog.record!(current_user, current_organization, "change_set.applied", change_set, target_program_version_id: result.target_program_version.id)
    if change_set.reload.export_ready?
      redirect_to change_set_path(change_set), notice: "Проект изменений применен. Новая редакция Word-документа и отчет сформированы."
    else
      redirect_to change_set_path(change_set), alert: "Документ сформирован как черновик, но финальная версия пока не готова."
    end
  rescue ChangeSetApplicationService::Error => error
    redirect_to change_set_path(change_set), alert: error.message
  end

  def approve_generated
    change_set = scoped_change_sets.find(params[:id])
    GeneratedVersionApprovalService.new(
      organization: current_organization,
      user: current_user
    ).approve_change_set!(change_set)
    redirect_to employee_user? ? employee_workspace_path : change_set_path(change_set), notice: "Новая редакция утверждена и стала активной."
  rescue GeneratedVersionApprovalService::Error => error
    redirect_to change_set_path(change_set), alert: error.message
  end

  def reject_generated
    change_set = scoped_change_sets.find(params[:id])
    if employee_user?
      request_employee_draft_feedback!(change_set)
      redirect_to employee_workspace_path
      return
    end

    GeneratedVersionApprovalService.new(
      organization: current_organization,
      user: current_user
    ).reject_change_set!(change_set)
    redirect_to change_sets_path, notice: "Черновик новой редакции отклонен."
  rescue GeneratedVersionApprovalService::Error => error
    redirect_to change_set_path(change_set), alert: error.message
  end

  def export_docx
    change_set = scoped_change_sets.find(params[:id])
    unless change_set.export_ready?
      redirect_to change_set_path(change_set), alert: "Финальный DOCX доступен только после успешной проверки"
      return
    end

    redirect_to rails_blob_path(change_set.generated_docx_attachment, disposition: "attachment")
  end

  def export_report
    change_set = scoped_change_sets.find(params[:id])
    unless change_set.export_ready?
      redirect_to change_set_path(change_set), alert: "Отчет доступен вместе с проверенной новой редакцией"
      return
    end

    redirect_to rails_blob_path(change_set.change_report_attachment, disposition: "attachment")
  end

  private

  def request_employee_draft_feedback!(change_set)
    conversation = AgentConversation.active_for!(
      organization: current_organization,
      user: current_user,
      audience: "employee"
    )
    state = conversation.working_state || {}
    conversation.update!(
      working_state: state.merge(
        "awaiting_draft_feedback" => true,
        "last_generated_change_set_id" => change_set.id,
        "last_offered_action" => "revise_generated_draft"
      ),
      memory_updated_at: Time.current
    )
    conversation.agent_messages.create!(
      role: "assistant",
      content: [
        "Черновик сохранен. Напишите, что именно нужно поправить в новой редакции.",
        "Если нажали случайно и файл правильный, напишите: «эта версия правильная, сделай ее актуальной»."
      ].join("\n\n"),
      metadata: {
        kind: "draft_feedback_request",
        change_set_id: change_set.id
      }
    )
    AuditLog.record!(
      current_user,
      current_organization,
      "generated_version.feedback_requested",
      change_set,
      target_program_version_id: change_set.target_program_version_id
    )
  end

  def scoped_change_sets
    ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: current_organization.id })
  end
end
