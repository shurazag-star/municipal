class DashboardController < ApplicationController
  before_action :require_admin!

  def index
    @organization = current_organization
    @programs = @organization.municipal_programs.order(updated_at: :desc).limit(20)
    @source_documents = @organization.source_documents.with_attached_file_attachment.order(created_at: :desc).limit(20)
    attached_documents = @source_documents.select { |document| document.file_attachment.attached? }
    @latest_documents_by_type = attached_documents.group_by(&:document_type).transform_values(&:first)
    @reconciliations = Reconciliation.joins(:source_document).where(source_documents: { organization_id: @organization.id }).order(year: :asc).limit(20)
    @llm_runs = LlmRun.where(organization: @organization).order(created_at: :desc).limit(5)
    @openrouter_configured = OpenRouterModelsClient.configured?
  end
end
