class SourceConflictDetector
  CHANGE_SOURCE_TYPES = %w[xlsx_finance pdf_agreement].freeze

  def initialize(match_results:)
    @match_results = Array(match_results)
  end

  def conflicts
    grouped_entries.filter_map do |key, entries|
      source_amounts = entries.each_with_object({}) do |entry, result|
        document_type = entry.fetch("document_type")
        next unless CHANGE_SOURCE_TYPES.include?(document_type)

        result[document_type] ||= entry
      end
      next unless source_amounts.key?("xlsx_finance") && source_amounts.key?("pdf_agreement")

      amounts = source_amounts.values.map { |entry| money(entry.fetch("amount_rub")) }.uniq
      next if amounts.one?

      object_key, year, source_type = key
      {
        "object_key" => object_key,
        "object_name" => entries.first["object_name"],
        "year" => year,
        "source_type" => source_type,
        "sources" => source_amounts.transform_values do |entry|
          {
            "source_document_id" => entry.fetch("source_document_id"),
            "filename" => entry.fetch("filename"),
            "amount_rub" => money(entry.fetch("amount_rub")),
            "evidence_text" => entry["evidence_text"],
            "page_number" => entry["page_number"]
          }.compact
        end
      }
    end
  end

  def conflict_for(result, entry)
    conflicts_by_key[entry_key(result, entry)]
  end

  private

  def grouped_entries
    @grouped_entries ||= @match_results.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |result, groups|
      Array(result.funding_entries).each do |entry|
        groups[entry_key(result, entry)] << normalized_entry(result, entry)
      end
    end
  end

  def conflicts_by_key
    @conflicts_by_key ||= conflicts.index_by { |conflict| [conflict["object_key"], conflict["year"], conflict["source_type"]] }
  end

  def entry_key(result, entry)
    [
      object_key(result),
      entry.fetch("year").to_i,
      entry.fetch("source_type").to_s
    ]
  end

  def object_key(result)
    return "node:#{result.program_node.id}" if result.program_node

    "name:#{normalize_name(result.source_reference&.fetch("object_name", nil).presence || result.external_group&.fetch("object_name", nil))}"
  end

  def normalized_entry(result, entry)
    {
      "document_type" => result.source_document.document_type,
      "object_name" => result.source_reference&.fetch("object_name", nil).presence || result.external_group&.fetch("object_name", nil),
      "source_document_id" => result.source_document.id,
      "filename" => result.source_document.filename,
      "amount_rub" => entry.fetch("amount_rub"),
      "evidence_text" => result.source_reference&.fetch("evidence_text", nil),
      "page_number" => entry["page_number"] || result.source_reference&.fetch("page_number", nil)
    }.compact
  end

  def normalize_name(value)
    value.to_s.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def money(value)
    format("%.2f", BigDecimal(value.to_s))
  end
end
