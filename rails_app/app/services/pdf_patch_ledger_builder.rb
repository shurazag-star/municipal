class PdfPatchLedgerBuilder
  POLICY = "pdf_is_partial_patch_not_target_model".freeze

  def initialize(analysis_session:, match_results:)
    @analysis_session = analysis_session
    @match_results = Array(match_results).select { |result| result.source_document&.pdf_agreement? }
  end

  def build
    return nil if @match_results.empty?

    entries = ledger_entries
    {
      "status" => status_for(entries),
      "policy" => POLICY,
      "source_mode" => @analysis_session.summary.to_h["source_mode"].presence || "pdf_patch",
      "documents" => documents_summary,
      "entries" => entries,
      "matched_count" => entries.count { |entry| entry["status"] == "matched" },
      "unmatched_count" => entries.count { |entry| entry["status"] == "unmatched" },
      "needs_confirmation_count" => entries.count { |entry| entry["status"] == "needs_confirmation" },
      "blocking_reasons" => blocking_reasons(entries)
    }
  end

  private

  def ledger_entries
    @match_results.flat_map do |result|
      result.funding_entries.map do |entry|
        {
          "source_document_id" => result.source_document.id,
          "filename" => result.source_document.filename,
          "object_name" => result.source_reference&.fetch("object_name", nil).presence || result.external_group["object_name"],
          "program_node_id" => result.program_node&.id,
          "match_status" => result.match_status,
          "status" => entry_status(result),
          "year" => entry["year"],
          "source_type" => entry["source_type"],
          "amount_mode" => entry["amount_mode"].presence || "absolute",
          "amount_rub" => money(entry["amount_rub"]),
          "delta_rub" => entry["delta_rub"].presence && money(entry["delta_rub"]),
          "from_year" => entry["from_year"],
          "to_year" => entry["to_year"],
          "transfer_pair" => entry["transfer_pair"].present?,
          "confidence" => result.confidence.to_s("F"),
          "page_number" => entry["page_number"] || result.source_reference&.fetch("page_number", nil),
          "evidence_text" => entry["evidence_text"].presence || result.source_reference&.fetch("evidence_text", nil)
        }.compact
      end
    end
  end

  def documents_summary
    @match_results.group_by(&:source_document).map do |document, results|
      pdf_control_sums = document.parsed_payload.to_h["pdf_control_sums"]
      {
        "source_document_id" => document.id,
        "filename" => document.filename,
        "changes_count" => results.sum { |result| result.funding_entries.size },
        "pdf_control_sums" => pdf_control_sums
      }.compact
    end
  end

  def entry_status(result)
    return "unmatched" unless result.program_node
    return "needs_confirmation" if result.requires_user_confirmation

    "matched"
  end

  def status_for(entries)
    blocking_reasons(entries).empty? ? "ready" : "blocked"
  end

  def blocking_reasons(entries)
    reasons = []
    reasons << "PDF не содержит структурированных изменений" if entries.empty?
    reasons << "PDF содержит строки, которые не сопоставлены с объектами программы" if entries.any? { |entry| entry["status"] == "unmatched" }
    reasons << "PDF содержит строки, требующие подтверждения перед применением" if entries.any? { |entry| entry["status"] == "needs_confirmation" }
    reasons << "Контрольные суммы PDF-таблицы не сходятся" if pdf_control_sum_failures.any?
    reasons
  end

  def pdf_control_sum_failures
    @pdf_control_sum_failures ||= @match_results.map(&:source_document).uniq.select do |document|
      document.parsed_payload.to_h.dig("pdf_control_sums", "status") == "failed"
    end
  end

  def money(value)
    format("%.2f", BigDecimal(value.to_s))
  rescue ArgumentError
    value.to_s
  end
end
