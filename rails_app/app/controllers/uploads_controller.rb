class UploadsController < ApplicationController
  before_action :require_admin!

  def create
    unless params[:file].present?
      redirect_to root_path, alert: "Выберите файл для загрузки"
      return
    end

    document_type = safe_document_type(params.fetch(:document_type, "other"))
    if (upload_error = SourceDocumentUploadPolicy.error_for(file: params[:file], document_type: document_type))
      redirect_to root_path, alert: upload_error
      return
    end

    document = SourceDocument.create!(
      organization: current_organization,
      document_type: document_type,
      filename: params[:file]&.original_filename || "unknown",
      status: "queued",
      created_by: current_user
    )
    document.file_attachment.attach(params[:file]) if params[:file].present?
    AuditLog.record!(current_user, current_organization, "source_document.uploaded", document, filename: document.filename)
    ParseDocumentJob.perform_later(document.id)
    redirect_to root_path, notice: "Файл загружен и поставлен на разбор: #{document.filename}"
  end

  private

  def safe_document_type(value)
    SourceDocument.document_types.key?(value.to_s) ? value.to_s : "other"
  end
end
