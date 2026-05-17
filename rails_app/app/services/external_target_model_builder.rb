class ExternalTargetModelBuilder
  DEFAULT_COVERAGE_THRESHOLD = BigDecimal("0.90")

  def initialize(analysis_session:, match_results:, coverage_threshold: nil)
    @analysis_session = analysis_session
    @match_results = Array(match_results)
    @program_version = analysis_session.program_version
    @organization = analysis_session.organization
    @coverage_threshold = BigDecimal((coverage_threshold || @organization.settings["excel_target_coverage_threshold"] || DEFAULT_COVERAGE_THRESHOLD).to_s)
  end

  def build
    coverage = coverage_metrics
    warnings = warnings_for(coverage)

    {
      "source_mode" => source_mode,
      "excel_absence_policy" => excel_absence_policy,
      "status" => "ready",
      "entries" => ledger_entries,
      "coverage" => coverage,
      "blocking_reasons" => [],
      "warnings" => warnings
    }
  end

  private

  def source_mode
    @analysis_session.effective_source_mode.presence || "xlsx_target"
  end

  def excel_absence_policy
    @organization.settings["excel_absence_policy"].presence || "zero_if_program_total_requires"
  end

  def ledger_entries
    excel_match_results.flat_map do |result|
      Array(result.funding_entries).map do |entry|
        {
          "object_identity" => object_identity(result),
          "program_node_id" => result.program_node&.id,
          "year" => entry.fetch("year").to_i,
          "source_type" => funding_source_value(entry.fetch("source_type")),
          "amount_rub" => money(entry.fetch("amount_rub")),
          "source_document_id" => result.source_document&.id,
          "row_number" => entry["row_number"] || result.source_reference&.fetch("row_number", nil),
          "source_evidence" => result.source_reference || {}
        }.compact
      end
    end
  end

  def coverage_metrics
    excel_total = excel_match_results.size
    excel_matched = excel_match_results.count { |result| result.program_node.present? }
    baseline_total = baseline_object_nodes.size
    baseline_matched = excel_match_results.filter_map(&:program_node).uniq.size
    baseline_absent = [baseline_total - baseline_matched, 0].max
    coverage = baseline_total.zero? ? BigDecimal("1") : BigDecimal(baseline_matched.to_s) / BigDecimal(baseline_total.to_s)

    {
      "excel_object_rows_total" => excel_total,
      "excel_object_rows_matched" => excel_matched,
      "excel_object_rows_unmatched" => excel_total - excel_matched,
      "baseline_objects_total" => baseline_total,
      "baseline_objects_matched_to_excel" => baseline_matched,
      "baseline_objects_absent_from_excel" => baseline_absent,
      "coverage_percent" => format("%.2f", coverage * 100)
    }
  end

  def warnings_for(coverage)
    warnings = []
    if coverage["excel_object_rows_unmatched"].to_i.positive?
      warnings << "Excel содержит строки объектов, которые нужно распределить автоматически"
    end
    coverage_percent = BigDecimal(coverage["coverage_percent"].to_s)
    if coverage_percent < (@coverage_threshold * 100)
      warnings << "Excel-цель покрывает #{coverage['coverage_percent']}% объектов программы; отсутствующие объекты DOCX будут обнулены как часть целевой модели"
    end
    warnings
  end

  def excel_match_results
    @excel_match_results ||= @match_results.select { |result| result.source_document&.xlsx_finance? }
  end

  def baseline_object_nodes
    @baseline_object_nodes ||= @program_version.program_nodes
      .includes(:funding_lines)
      .where(node_type: %w[object residual])
      .select { |node| node.funding_lines.any? }
  end

  def object_identity(result)
    result.external_group["object_code"].presence ||
      result.external_group["object_name"].presence ||
      result.program_node&.name
  end

  def money(amount)
    format("%.2f", BigDecimal(amount.to_s))
  end

  def funding_source_value(raw)
    FundingSourceCatalog.normalize(FundingLine.source_types.fetch(raw.to_s, raw.to_s), organization: @organization)
  end
end
