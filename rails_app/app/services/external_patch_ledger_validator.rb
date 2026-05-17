class ExternalPatchLedgerValidator
  def initialize(change_set:, target_program_version:, ledger:, post_export_validation:)
    @change_set = change_set
    @target_program_version = target_program_version
    @ledger = ledger || {}
    @post_export_validation = post_export_validation || {}
    @tolerance = BigDecimal(AgentSetting.for_organization!(@change_set.program_version.municipal_program.organization).money_tolerance_rub.to_s)
  end

  def validate
    entries = Array(@ledger["entries"]).map { |entry| validate_entry(entry) }
    failures = entries.select { |entry| entry["validation_status"] == "failed" }
    failed = failures.any? || entries.empty?
    {
      "status" => failed ? "failed" : "passed",
      "entries_count" => entries.size,
      "failed_count" => failures.size,
      "entries" => entries,
      "blocking_reasons" => blocking_reasons(failures)
    }
  end

  private

  def validate_entry(entry)
    target_node = target_node_for(entry)
    return entry.merge("validation_status" => "failed", "validation_reason" => "Целевой объект после применения не найден") unless target_node

    actual = target_amount(target_node, entry)
    expected = BigDecimal(entry["expected_after_rub"].to_s)
    delta = actual - expected
    docx_error = matching_docx_error(entry)
    if delta.abs > @tolerance
      return entry.merge(
        "validation_status" => "failed",
        "validation_reason" => "Расчетное дерево после применения не совпадает с PDF-операцией",
        "actual_after_rub" => money(actual),
        "delta_rub" => money(delta)
      )
    end
    if docx_error
      return entry.merge(
        "validation_status" => "failed",
        "validation_reason" => docx_error["message"].presence || "DOCX-проверка нашла расхождение по объекту PDF-операции",
        "actual_after_rub" => money(actual),
        "delta_rub" => money(delta),
        "docx_error" => docx_error
      )
    end

    entry.merge(
      "validation_status" => "passed",
      "actual_after_rub" => money(actual),
      "delta_rub" => money(delta)
    )
  rescue ArgumentError => error
    entry.merge("validation_status" => "failed", "validation_reason" => "Некорректная сумма в PDF-журнале: #{error.message}")
  end

  def target_node_for(entry)
    target_id = entry["target_program_node_id"].presence
    return @target_program_version.program_nodes.includes(:funding_lines).find_by(id: target_id) if target_id

    source_id = entry["source_program_node_id"].presence
    return nil unless source_id

    @target_program_version.program_nodes
      .includes(:funding_lines)
      .find_by("metadata ->> 'source_program_node_id' = ?", source_id.to_s)
  end

  def target_amount(node, entry)
    year = entry["year"].to_i
    source_type = funding_source_value(entry["source_type"])
    node.funding_lines.select do |line|
      line.year.to_i == year && funding_source_value(line.source_type) == source_type
    end.sum(BigDecimal("0")) { |line| BigDecimal(line.amount_rub.to_s) }
  end

  def matching_docx_error(entry)
    (Array(@post_export_validation.dig("object_funding", "errors")) + Array(@post_export_validation["errors"]).select { |error| error["code"] == "object_funding_mismatch" }).detect do |error|
      error["year"].to_i == entry["year"].to_i &&
        funding_source_value(error["source_type"]) == funding_source_value(entry["source_type"]) &&
        normalize_name(error["object_name"]) == normalize_name(entry["object_name"])
    end
  end

  def blocking_reasons(failures)
    reasons = []
    reasons << "PDF-журнал не содержит применяемых операций" if Array(@ledger["entries"]).empty?
    reasons << "Не все операции PDF подтверждены расчетным деревом и DOCX-проверкой" if failures.any?
    reasons
  end

  def money(value)
    format("%.2f", BigDecimal(value.to_s))
  end

  def funding_source_value(raw)
    FundingSourceCatalog.normalize(
      FundingLine.source_types.fetch(raw.to_s, raw.to_s),
      organization: @change_set.program_version.municipal_program.organization
    )
  end

  def normalize_name(value)
    value.to_s.downcase.tr("Ёё", "ее").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end
end
