class ImportsController < ApplicationController
  before_action :require_admin!

  def docx
    enqueue_import!("docx_program")
  end

  def procedure_pdf
    enqueue_import!("pdf_procedure")
  end

  def finance_xlsx
    enqueue_import!("xlsx_finance")
  end

  def agreement_pdf
    enqueue_import!("pdf_agreement")
  end

  private

  def enqueue_import!(document_type)
    document = current_organization.source_documents.find(params[:source_document_id])
    document.update!(document_type: document_type, status: "queued")
    ParseDocumentJob.perform_later(document.id)
    redirect_to root_path, notice: "Импорт поставлен в очередь"
  end
end
