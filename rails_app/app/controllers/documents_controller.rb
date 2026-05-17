class DocumentsController < ApplicationController
  before_action :require_admin!

  def export
    document = current_organization.source_documents.find(params[:id])
    AuditLog.record!(current_user, current_organization, "document.export_requested", document)
    redirect_to root_path, notice: "Экспорт будет сформирован worker-процессом"
  end
end
