class KnowledgeChunksController < ApplicationController
  before_action :require_admin!

  CHUNK_TYPE_LABELS = {
    "procedure_general" => "Общие положения",
    "program_structure" => "Структура программы",
    "indicators_and_results" => "Показатели и результаты",
    "change_procedure" => "Порядок внесения изменений",
    "approval_terms" => "Согласование и сроки",
    "forms" => "Формы и приложения",
    "reporting" => "Отчетность",
    "text" => "Текст"
  }.freeze

  def index
    @procedure_document = current_organization.source_documents.where(document_type: "pdf_procedure").order(updated_at: :desc).first
    @query = params[:q].to_s.strip
    @chunks = KnowledgeRetriever.new(organization: current_organization).search(query: @query)
    @chunk_count = current_organization.knowledge_chunks.count
    @chunk_type_labels = CHUNK_TYPE_LABELS
  end
end
