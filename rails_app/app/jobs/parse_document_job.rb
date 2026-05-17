class ParseDocumentJob < ApplicationJob
  queue_as :default

  def perform(source_document_id)
    document = SourceDocument.find(source_document_id)
    document.update!(status: "parsing")
    payload = parser_worker_client.parse(document) || {}
    document.update!(status: "parsed", parsed_payload: payload)
    profile = build_document_profile(document)
    KnowledgeIndexer.new(document).index! if document.pdf_procedure?
    if document.docx_program?
      version = ProgramTreePersister.new(source_document: document, user: document.created_by).persist!
      profile&.update!(municipal_program: version.municipal_program) if profile&.municipal_program_id.blank?
    end
    ReconciliationBuilder.new(organization: document.organization, user: document.created_by).refresh!
    AuditLog.record!(document.created_by, document.organization, "source_document.parsed", document, parser: "parser_worker")
  rescue StandardError => error
    document&.update!(
      status: "failed",
      parsed_payload: (document.parsed_payload || {}).merge(
        "error" => error.class.name,
        "message" => error.message
      )
    )
    AuditLog.record!(document&.created_by, document&.organization, "source_document.parse_failed", document, error: error.class.name, message: error.message) if document
  end

  private

  def parser_worker_client
    configured = Rails.application.config.x.parser_worker_client
    if configured.respond_to?(:parse) && !configured.is_a?(ActiveSupport::OrderedOptions)
      configured
    else
      ParserWorkerClient.new
    end
  end

  def build_document_profile(document)
    return unless profile_supported?(document)

    DocumentProfileBuilder.new(source_document: document).build!
  end

  def profile_supported?(document)
    document.docx_program? || document.xlsx_finance? || document.pdf_procedure? || document.pdf_agreement?
  end
end
