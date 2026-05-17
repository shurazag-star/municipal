class EmployeeDocumentsController < ApplicationController
  before_action :require_employee!

  def create
    unless params[:file].present?
      redirect_to employee_workspace_path, alert: "Выберите файл для загрузки"
      return
    end

    document_type = document_type_for(params[:slot], params[:file].original_filename)
    if (upload_error = SourceDocumentUploadPolicy.error_for(file: params[:file], document_type: document_type))
      redirect_to employee_workspace_path, alert: upload_error
      return
    end

    document = SourceDocument.create!(
      organization: current_organization,
      document_type: document_type,
      filename: params[:file].original_filename,
      status: "queued",
      created_by: current_user
    )
    document.file_attachment.attach(params[:file])
    AuditLog.record!(current_user, current_organization, "employee_document.uploaded", document, filename: document.filename, slot: params[:slot])
    ParseDocumentJob.perform_later(document.id)
    redirect_to employee_workspace_path, notice: "Файл принят: #{document.filename}"
  end

  def destroy
    document = current_organization.source_documents.find(params[:id])
    filename = document.filename
    document.destroy!
    AuditLog.record!(current_user, current_organization, "employee_document.deleted", nil, filename: filename, source_document_id: document.id)
    redirect_to employee_workspace_path, notice: "Поле очищено: #{filename}"
  rescue ActiveRecord::InvalidForeignKey
    redirect_to employee_workspace_path, alert: "Файл сейчас связан с обработкой. Обновите страницу и повторите удаление."
  end

  def clear_current_program
    ActiveRecord::Base.transaction do
      reset_change_artifacts!
      current_organization.manual_change_instructions.destroy_all
      AgentMatchDecision.where(organization: current_organization).destroy_all
      current_organization.municipal_programs.destroy_all
      destroy_source_documents(current_organization.source_documents.where(document_type: "docx_program"))
      AuditLog.record!(current_user, current_organization, "employee_workspace.current_program_deleted", current_organization)
    end

    redirect_to employee_workspace_path, notice: "Актуальная программа удалена. Остальные документы сохранены."
  rescue ActiveRecord::InvalidForeignKey
    redirect_to employee_workspace_path, alert: "Актуальная программа сейчас связана с обработкой. Обновите страницу и повторите удаление."
  end

  def clear_all
    ActiveRecord::Base.transaction do
      reset_all_workspace_data!
      reset_employee_conversation!
      AuditLog.record!(current_user, current_organization, "employee_workspace.clear_all_documents", current_organization)
    end

    redirect_to employee_workspace_path, notice: "Документы, редакции и проекты удалены. Рабочий кабинет очищен."
  rescue ActiveRecord::InvalidForeignKey
    redirect_to employee_workspace_path, alert: "Документы сейчас связаны с обработкой. Обновите страницу и повторите очистку."
  end

  private

  def require_employee!
    redirect_to root_path if current_user&.admin?
  end

  def document_type_for(slot, filename)
    case slot.to_s
    when "procedure"
      "pdf_procedure"
    when "program"
      "docx_program"
    when "change_source"
      change_source_type(filename)
    else
      "other"
    end
  end

  def change_source_type(filename)
    extension = File.extname(filename.to_s).downcase
    return "xlsx_finance" if extension.in?(%w[.xls .xlsx .csv])
    return "pdf_agreement" if extension == ".pdf"

    "other"
  end

  def reset_all_workspace_data!
    reset_change_artifacts!
    current_organization.manual_change_instructions.destroy_all
    AgentMatchDecision.where(organization: current_organization).destroy_all
    current_organization.municipal_programs.destroy_all
    current_organization.knowledge_chunks.destroy_all
    current_organization.municipal_document_profiles.destroy_all
    destroy_source_documents(current_organization.source_documents)
    current_organization.procedure_documents.destroy_all
  end

  def reset_change_artifacts!
    scoped_change_sets.destroy_all
    current_organization.analysis_sessions.destroy_all
  end

  def scoped_change_sets
    ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: current_organization.id })
  end

  def destroy_source_documents(scope)
    scope.find_each(&:destroy!)
  end

  def reset_employee_conversation!
    conversation = AgentConversation.active_for!(organization: current_organization, user: current_user, audience: "employee")
    conversation.reset_with_welcome!(audience: "employee")
  end
end
