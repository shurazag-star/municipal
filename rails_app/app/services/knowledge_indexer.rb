class KnowledgeIndexer
  DEFAULT_CHUNK_TYPE = "procedure_general".freeze

  def initialize(source_document)
    @source_document = source_document
    @organization = source_document.organization
  end

  def index!
    return [] unless @source_document.pdf_procedure?

    @source_document.knowledge_chunks.delete_all
    chunk_payloads.filter_map do |payload|
      content = payload["content"].to_s.strip
      next if content.blank?

      @source_document.knowledge_chunks.create!(
        organization: @organization,
        chunk_type: payload["chunk_type"].presence || DEFAULT_CHUNK_TYPE,
        title: payload["title"].presence || default_title(payload),
        content: content,
        page_number: payload["page_number"],
        table_index: payload["table_index"],
        row_index: payload["row_index"],
        metadata: payload["metadata"].presence || {}
      )
    end
  end

  private

  def chunk_payloads
    payload = @source_document.parsed_payload || {}
    chunks = Array(payload["chunks"])
    return chunks if chunks.any?

    Array(payload["rules"]).map.with_index(1) do |rule, index|
      {
        "chunk_type" => DEFAULT_CHUNK_TYPE,
        "title" => "Правило #{index}",
        "content" => rule.to_s,
        "metadata" => { "source" => "legacy_rules" }
      }
    end
  end

  def default_title(payload)
    type = payload["chunk_type"].presence || DEFAULT_CHUNK_TYPE
    "Фрагмент базы знаний: #{type}"
  end
end
