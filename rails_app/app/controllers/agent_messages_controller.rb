class AgentMessagesController < ApplicationController
  def create
    uploaded_document = attach_document_from_chat if params[:attachment].present?
    return if performed?

    content = message_content_with_attachment(params[:content].to_s, uploaded_document)

    if content.blank? && params[:quick_action].blank?
      redirect_to current_workspace_path, alert: "Напишите сообщение или прикрепите документ"
      return
    end

    AgentOrchestrator.new(organization: current_organization, user: current_user).call(
      content: content,
      quick_action: params[:quick_action].presence,
      uploaded_document: uploaded_document
    )
    redirect_to current_workspace_path, notice: uploaded_document ? "Файл прикреплен и поставлен на разбор: #{uploaded_document.filename}" : nil
  end

  private

  def attach_document_from_chat
    upload = params[:attachment]
    document_type = safe_document_type
    if (upload_error = SourceDocumentUploadPolicy.error_for(file: upload, document_type: document_type))
      redirect_to current_workspace_path, alert: upload_error
      return nil
    end

    document = SourceDocument.create!(
      organization: current_organization,
      document_type: document_type,
      filename: upload.original_filename,
      status: "queued",
      created_by: current_user
    )
    document.file_attachment.attach(upload)
    AuditLog.record!(current_user, current_organization, "source_document.uploaded_from_chat", document, filename: document.filename)
    ParseDocumentJob.perform_later(document.id)
    document
  end

  def safe_document_type
    requested = params[:document_type].presence || "other"
    SourceDocument.document_types.key?(requested) ? requested : "other"
  end

  def message_content_with_attachment(content, uploaded_document)
    return content if uploaded_document.blank?

    attachment_line = "Прикреплен файл: #{uploaded_document.filename}"
    [ content.presence, attachment_line ].compact.join("\n\n")
  end
end
