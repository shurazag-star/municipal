class ExternalPatchLedgerBuilder
  POLICY = "pdf_patch_operations_must_be_visible_after_export".freeze

  def initialize(change_set:, target_program_version:, new_object_result: {})
    @change_set = change_set
    @target_program_version = target_program_version
    @new_object_result = new_object_result || {}
  end

  def build
    entries = pdf_change_items.map { |item| entry_for(item) }
    {
      "status" => entries.empty? ? "empty" : "ready",
      "policy" => POLICY,
      "source_mode" => @change_set.analysis_session&.effective_source_mode || "pdf_patch",
      "entries" => entries,
      "entries_count" => entries.size,
      "blocking_reasons" => entries.empty? ? ["PDF-журнал не содержит применяемых операций"] : []
    }
  end

  private

  def pdf_change_items
    @pdf_change_items ||= @change_set.change_items
      .active_for_application
      .includes(:program_node)
      .order(:id)
      .select { |item| item.source_reference.to_h["document_type"] == "pdf_agreement" }
  end

  def entry_for(item)
    reference = item.source_reference || {}
    {
      "change_item_id" => item.id,
      "change_type" => item.change_type,
      "source_document_id" => reference["source_document_id"],
      "filename" => reference["filename"],
      "page_number" => reference["page_number"],
      "object_name" => item.program_node&.name.presence || item.new_value.presence || reference["object_name"],
      "source_program_node_id" => item.program_node_id,
      "target_program_node_id" => target_node_id_for(item),
      "year" => item.year,
      "source_type" => funding_source_value(item.source_type),
      "before_rub" => money(item.old_amount_rub || 0),
      "operation" => operation_for(item),
      "operation_delta_rub" => money(item.delta_rub || item.new_amount_rub || 0),
      "expected_after_rub" => money(item.new_amount_rub || 0),
      "amount_mode" => reference["amount_mode"].presence || reference["original_amount_mode"].presence || "absolute",
      "evidence_text" => reference["evidence_text"],
      "text_extraction_method" => reference["text_extraction_method"],
      "ocr_applied" => reference["ocr_applied"].present?
    }.compact
  end

  def target_node_id_for(item)
    return @new_object_result.dig("target_node_ids_by_item_id", item.id.to_s) if item.new_object?

    @target_program_version.program_nodes.find_by("metadata ->> 'source_program_node_id' = ?", item.program_node_id.to_s)&.id
  end

  def operation_for(item)
    mode = item.source_reference.to_h["amount_mode"].presence || item.source_reference.to_h["original_amount_mode"].presence
    return "set_absolute_amount" if mode.blank? || mode == "absolute"
    return "subtract_delta" if mode == "delta_minus"
    return "add_delta" if mode == "delta_plus"

    mode
  end

  def money(value)
    format("%.2f", BigDecimal(value.to_s))
  rescue ArgumentError
    value.to_s
  end

  def funding_source_value(raw)
    FundingSourceCatalog.normalize(
      FundingLine.source_types.fetch(raw.to_s, raw.to_s),
      organization: @change_set.program_version.municipal_program.organization
    )
  end
end
