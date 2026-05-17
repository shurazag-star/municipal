class ReconciliationsController < ApplicationController
  before_action :require_admin!

  def create
    version = current_organization.program_versions.find(params[:program_version_id])
    source_document = current_organization.source_documents.find(params[:source_document_id])
    reconciliation = Reconciliation.create!(
      program_version: version,
      source_document: source_document,
      status: "queued",
      details: {}
    )
    AuditLog.record!(current_user, current_organization, "reconciliation.created", reconciliation)
    redirect_to reconciliation_path(reconciliation)
  end

  def show
    @reconciliation = Reconciliation.joins(:source_document)
      .where(source_documents: { organization_id: current_organization.id })
      .find_by(id: params[:id])
    head :not_found unless @reconciliation
  end
end
