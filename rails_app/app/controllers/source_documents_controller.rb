class SourceDocumentsController < ApplicationController
  before_action :require_admin!

  def index
    @procedure_documents = scoped_documents.where(document_type: "pdf_procedure").order(updated_at: :desc)
    @program_documents = scoped_documents.where(document_type: "docx_program").order(updated_at: :desc)
    @change_source_documents = scoped_documents.where(document_type: %w[xlsx_finance pdf_agreement other]).order(updated_at: :desc)
    @source_mode = SourceModeResolver.new(organization: current_organization)
    @generated_documents = ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: current_organization.id })
      .where(status: "applied")
      .order(updated_at: :desc)
      .select(&:export_ready?)
  end

  def show
    @source_document = scoped_documents.find_by(id: params[:id])
    head :not_found unless @source_document
  end

  def create
    unless params[:file].present?
      redirect_to source_documents_path, alert: "Выберите файл для загрузки"
      return
    end

    document_type = safe_document_type(params.fetch(:document_type, "other"))
    if (upload_error = SourceDocumentUploadPolicy.error_for(file: params[:file], document_type: document_type))
      redirect_to source_documents_path, alert: upload_error
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
    AuditLog.record!(current_user, current_organization, "source_document.uploaded", document, filename: document.filename)
    ParseDocumentJob.perform_later(document.id)
    redirect_to source_documents_path, notice: "Файл загружен и поставлен на разбор: #{document.filename}"
  end

  def destroy
    document = scoped_documents.find_by(id: params[:id])
    unless document
      head :not_found
      return
    end

    filename = document.filename
    document.destroy!
    AuditLog.record!(
      current_user,
      current_organization,
      "source_document.deleted",
      current_organization,
      filename: filename,
      source_document_id: document.id
    )
    redirect_to source_documents_path, notice: "Файл удален: #{filename}"
  rescue ActiveRecord::InvalidForeignKey => error
    handle_source_document_delete_error(error)
  end

  def make_active
    document = scoped_documents.find_by(id: params[:id], document_type: "docx_program")
    unless document
      head :not_found
      return
    end

    if document.status == "parsed" && current_organization.program_versions.where("import_summary ->> 'source_document_id' = ?", document.id.to_s).none?
      ProgramTreePersister.new(source_document: document, user: current_user).persist!
    end
    versions = current_organization.program_versions.where("import_summary ->> 'source_document_id' = ?", document.id.to_s)
    version = versions.where(status: "imported").order(version_number: :desc).first || versions.order(version_number: :desc).first
    unless version
      redirect_to source_documents_path, alert: "Для этого DOCX еще не создана версия программы. Дождитесь разбора файла."
      return
    end
    program = version.municipal_program
    program.current_version&.update!(status: "uploaded_inactive") if program.current_version && program.current_version.id != version.id && program.current_version.uploaded_active_status?
    program.update!(current_version: version)
    version.update!(status: "uploaded_active")
    AuditLog.record!(current_user, current_organization, "source_document.made_active", document, program_version_id: version.id)
    redirect_to source_documents_path, notice: "Текущая программа обновлена"
  end

  def set_source_mode
    source_mode = SourceModeResolver.normalize(params[:source_mode])
    unless source_mode
      redirect_to source_documents_path, alert: "Неизвестный режим документов-оснований"
      return
    end

    current_organization.update!(
      settings: (current_organization.settings || {}).merge("default_source_mode" => source_mode)
    )
    redirect_to source_documents_path, notice: "Режим документов-оснований обновлен: #{SourceModeResolver.label(source_mode)}"
  end

  def clear_change_sources
    reset_change_projects!
    destroy_source_documents(scoped_documents.where(document_type: %w[xlsx_finance pdf_agreement other]))
    AuditLog.record!(current_user, current_organization, "workspace.clear_change_sources", current_organization)
    redirect_to source_documents_path, notice: "Документы-основания и связанные проекты очищены"
  rescue ActiveRecord::InvalidForeignKey => error
    handle_source_document_delete_error(error)
  end

  def clear_change_projects
    reset_change_projects!
    AuditLog.record!(current_user, current_organization, "workspace.clear_change_projects", current_organization)
    redirect_to source_documents_path, notice: "Проекты изменений очищены"
  end

  def clear_program_versions
    reset_change_projects!
    current_organization.municipal_programs.destroy_all
    AuditLog.record!(current_user, current_organization, "workspace.clear_program_versions", current_organization)
    redirect_to source_documents_path, notice: "Версии программы очищены"
  end

  def clear_workspace
    reset_change_projects!
    current_organization.municipal_programs.destroy_all
    current_organization.knowledge_chunks.destroy_all
    destroy_source_documents(scoped_documents)
    current_organization.procedure_documents.destroy_all
    AuditLog.record!(current_user, current_organization, "workspace.clear_all", current_organization)
    redirect_to source_documents_path, notice: "Рабочие данные очищены. Настройки агента и OpenRouter сохранены."
  rescue ActiveRecord::InvalidForeignKey => error
    handle_source_document_delete_error(error)
  end

  private

  def safe_document_type(value)
    SourceDocument.document_types.key?(value.to_s) ? value.to_s : "other"
  end

  def scoped_documents
    current_organization.source_documents
  end

  def destroy_source_documents(scope)
    scope.find_each(&:destroy!)
  end

  def reset_change_projects!
    scoped_change_sets.destroy_all
    current_organization.analysis_sessions.destroy_all
  end

  def scoped_change_sets
    ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: current_organization.id })
  end

  def handle_source_document_delete_error(error)
    Rails.logger.warn(
      "source_document_delete_failed " \
      "organization_id=#{current_organization&.id} " \
      "document_id=#{params[:id]} " \
      "error=#{error.class.name}: #{error.message}"
    )
    redirect_to source_documents_path,
                alert: "Файл не удален из-за фоновой обработки. Обновите страницу и повторите удаление."
  end
end
