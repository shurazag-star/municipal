class KnowledgeRetriever
  DEFAULT_LIMIT = 50

  def initialize(organization:)
    @organization = organization
  end

  def search(query:, limit: DEFAULT_LIMIT)
    scope = @organization.knowledge_chunks
      .includes(:source_document)
      .joins(:source_document)
      .where(source_documents: { document_type: "pdf_procedure" })
      .order(updated_at: :desc, id: :desc)

    sanitized_query = query.to_s.strip
    if sanitized_query.present?
      tokens = sanitized_query.downcase.scan(/[[:alnum:]а-яё]{4,}/i).uniq.first(6)
      if tokens.any?
        conditions = tokens.map.with_index do |_token, index|
          ":pattern_#{index}"
        end
        sql = conditions.map do |placeholder|
          "knowledge_chunks.title ILIKE #{placeholder} OR knowledge_chunks.content ILIKE #{placeholder} OR knowledge_chunks.chunk_type ILIKE #{placeholder}"
        end.join(" OR ")
        binds = tokens.map.with_index.to_h do |token, index|
          [:"pattern_#{index}", "%#{ActiveRecord::Base.sanitize_sql_like(token)}%"]
        end
        scope = scope.where(sql, binds)
      end
    end

    scope.limit(limit)
  end
end
