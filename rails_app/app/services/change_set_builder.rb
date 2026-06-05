require "set"

class ChangeSetBuilder
  def initialize(analysis_session:, match_results:)
    @analysis_session = analysis_session
    @match_results = Array(match_results)
    @organization = analysis_session.organization
    @program_version = analysis_session.program_version
    @user = analysis_session.user
    setting = AgentSetting.for_organization!(@organization)
    @tolerance = BigDecimal(setting.money_tolerance_rub.to_s)
    @threshold = BigDecimal(setting.match_confidence_threshold.to_s)
  end

  def build!
    return nil if @match_results.empty?

    ActiveRecord::Base.transaction do
      change_set = ChangeSet.create!(
        analysis_session: @analysis_session,
        program_version: @program_version,
        source_document: primary_source_document,
        status: "draft",
        summary: "Проект изменений по результатам анализа ##{@analysis_session.id}",
        created_by: @user
      )

      @match_results.each do |match_result|
        if match_result.program_node
          create_amount_items!(change_set, match_result)
        else
          create_new_object_items!(change_set, match_result)
        end
      end
      create_absent_excel_zeroing_items!(change_set)

      change_set.refresh_summary!
      change_set
    end
  end

  private

  def create_amount_items!(change_set, match_result)
    prepared_entries = target_state_entries(match_result).map do |entry|
      old_amount = current_amount(match_result.program_node, entry.fetch("year"), entry.fetch("source_type"))
      new_amount = new_amount_for_entry(old_amount, entry)
      {
        entry: entry,
        old_amount: old_amount,
        new_amount: new_amount,
        delta: new_amount - old_amount
      }
    end
    tiny_reallocation_keys = tiny_excel_source_reallocation_keys(match_result, prepared_entries)

    prepared_entries.each do |prepared|
      entry = prepared.fetch(:entry)
      old_amount = prepared.fetch(:old_amount)
      new_amount = prepared.fetch(:new_amount)
      delta = prepared.fetch(:delta)
      requires_confirmation = match_result.requires_user_confirmation || entry_requires_confirmation?(entry, match_result)
      next if tiny_reallocation_keys.include?(funding_key(entry.fetch("year"), entry.fetch("source_type")))
      next if delta.abs <= @tolerance && !requires_confirmation

      item = change_set.change_items.create!(
        program_node: match_result.program_node,
        change_type: "amount_update",
        status: "draft",
        field_name: "amount_rub",
        year: entry.fetch("year"),
        source_type: entry.fetch("source_type"),
        old_value: old_amount.to_s("F"),
        new_value: new_amount.to_s("F"),
        old_amount_rub: old_amount,
        new_amount_rub: new_amount,
        delta_rub: delta,
        source_reference: source_reference(match_result, entry),
        confidence: match_result.confidence,
        requires_user_confirmation: false,
        agent_resolution_status: "unresolved",
        agent_resolution_reason: initial_resolution_reason(requires_confirmation, entry, match_result),
        explanation: match_result.candidate.reason
      )
      SemanticMatchDecisionApplier.new(change_item: item).apply!
    end
  end

  def tiny_excel_source_reallocation_keys(match_result, prepared_entries)
    return Set.new unless match_result.source_document&.xlsx_finance?

    max_source_noise = [@tolerance * BigDecimal("20"), BigDecimal("200")].max
    prepared_entries.group_by { |prepared| prepared.fetch(:entry).fetch("year").to_i }.each_with_object(Set.new) do |(_year, entries), result|
      absolute_entries = entries.select { |prepared| absolute_excel_target_entry?(prepared.fetch(:entry)) }
      next if absolute_entries.size < 2

      total_delta = absolute_entries.sum { |prepared| prepared.fetch(:delta) }
      next if total_delta.abs > @tolerance
      next unless absolute_entries.any? { |prepared| prepared.fetch(:delta).positive? } &&
        absolute_entries.any? { |prepared| prepared.fetch(:delta).negative? }
      next unless absolute_entries.all? { |prepared| prepared.fetch(:delta).abs <= max_source_noise }

      absolute_entries.each do |prepared|
        entry = prepared.fetch(:entry)
        result << funding_key(entry.fetch("year"), entry.fetch("source_type"))
      end
    end
  end

  def absolute_excel_target_entry?(entry)
    mode = entry["amount_mode"].presence || "absolute"
    mode == "absolute" &&
      entry["target_model_absent_in_excel"].blank? &&
      entry["explicit_zero_target"].blank?
  end

  def create_new_object_items!(change_set, match_result)
    match_result.funding_entries.each do |entry|
      amount = BigDecimal(entry.fetch("amount_rub").to_s)
      item = change_set.change_items.create!(
        change_type: "new_object",
        status: "draft",
        field_name: "object",
        year: entry.fetch("year"),
        source_type: entry.fetch("source_type"),
        new_value: match_result.external_group["object_name"].presence || "Новый объект",
        new_amount_rub: amount,
        delta_rub: amount,
        source_reference: source_reference(match_result, entry),
        confidence: match_result.confidence,
        requires_user_confirmation: false,
        agent_resolution_status: "unresolved",
        agent_resolution_reason: "Новый объект будет сопоставлен агентом с разделом программы.",
        explanation: match_result.candidate.reason
      )
      SemanticMatchDecisionApplier.new(change_item: item).apply!
    end
  end

  def create_absent_excel_zeroing_items!(change_set)
    return unless excel_target_mode?
    return unless excel_absent_zeroing_enabled?

    source_document = primary_excel_source_document
    return unless source_document

    matched_node_ids = @match_results
      .select { |result| result.source_document&.xlsx_finance? && result.program_node.present? }
      .map { |result| result.program_node.id }
      .to_set

    baseline_financial_nodes.each do |node|
      next if matched_node_ids.include?(node.id)

      existing_funding_keys(node).each do |year, source_type|
        next unless excel_target_year_in_scope?(year)

        old_amount = current_amount(node, year, source_type)
        next if old_amount.abs <= @tolerance

        change_set.change_items.create!(
          program_node: node,
          change_type: "amount_update",
          status: "draft",
          field_name: "amount_rub",
          year: year,
          source_type: source_type,
          old_value: old_amount.to_s("F"),
          new_value: "0",
          old_amount_rub: old_amount,
          new_amount_rub: BigDecimal("0"),
          delta_rub: -old_amount,
          source_reference: {
            "source_document_id" => source_document.id,
            "filename" => source_document.filename,
            "document_type" => source_document.document_type,
            "match_status" => "ABSENT_IN_EXCEL_TARGET",
            "amount_mode" => "zeroing",
            "target_model_absent_in_excel" => true,
            "year" => year,
            "source_type" => source_type
          },
          confidence: BigDecimal("1.0"),
          requires_user_confirmation: false,
          agent_resolution_status: "unresolved",
          agent_resolution_reason: "Объект есть в DOCX, но отсутствует в Excel-целевой модели; сумма будет обнулена."
        )
      end
    end
  end

  def current_amount(program_node, year, source_type)
    program_node.funding_lines.select do |line|
      line.year == year.to_i && funding_source_value(line.source_type) == funding_source_value(source_type)
    end.reduce(BigDecimal("0")) { |sum, line| sum + BigDecimal(line.amount_rub.to_s) }
  end

  def source_reference(match_result, entry)
    match_result.source_reference.merge(
      "match_status" => match_result.match_status,
      "group_status" => match_result.external_group["status"],
      "year" => entry.fetch("year"),
      "source_type" => entry.fetch("source_type"),
	      "page_number" => entry["page_number"] || match_result.source_reference["page_number"],
	      "amount_mode" => entry["amount_mode"],
	      "delta_rub" => entry["delta_rub"],
	      "explicit_zero_target" => entry["explicit_zero_target"] || match_result.external_group["explicit_zero_target"],
	      "target_model_absent_in_excel" => entry["target_model_absent_in_excel"],
      "from_year" => entry["from_year"],
      "to_year" => entry["to_year"],
      "transfer_pair" => entry["transfer_pair"],
      "original_amount_mode" => entry["original_amount_mode"],
      "evidence_text" => entry["evidence_text"] || match_result.source_reference["evidence_text"],
      "text_extraction_method" => entry["text_extraction_method"] || match_result.source_reference["text_extraction_method"],
      "ocr_applied" => entry["ocr_applied"] || match_result.source_reference["ocr_applied"],
      "ocr_warnings" => entry["ocr_warnings"] || match_result.source_reference["ocr_warnings"]
    ).compact
  end

  def target_state_entries(match_result)
    entries = match_result.funding_entries.map(&:dup)
    if match_result.external_group["explicit_zero_target"].present?
      entries = zeroing_entries_for_existing_funding(match_result, explicit_zero_target: true)
      return entries
    end
    return entries unless match_result.source_document&.xlsx_finance? && match_result.program_node.present?
    return entries unless excel_absent_zeroing_enabled?

    target_keys = entries.map { |entry| funding_key(entry.fetch("year"), entry.fetch("source_type")) }.to_set
    existing_funding_keys(match_result.program_node).each do |year, source_type|
      next if target_keys.include?(funding_key(year, source_type))
      next unless excel_target_year_in_scope?(year)

      old_amount = current_amount(match_result.program_node, year, source_type)
      next if old_amount.abs <= @tolerance

      entries << {
        "year" => year,
	        "source_type" => source_type,
	        "amount_rub" => BigDecimal("0"),
	        "amount_mode" => "zeroing",
	        "explicit_zero_target" => match_result.external_group["explicit_zero_target"],
	        "target_model_absent_in_excel" => true
	      }
    end
    entries
  end

  def zeroing_entries_for_existing_funding(match_result, explicit_zero_target:)
    return [] unless match_result.source_document&.xlsx_finance? && match_result.program_node.present?

    existing_funding_keys(match_result.program_node).filter_map do |year, source_type|
      next unless excel_target_year_in_scope?(year)

      old_amount = current_amount(match_result.program_node, year, source_type)
      next if old_amount.abs <= @tolerance

      {
        "year" => year,
        "source_type" => source_type,
        "amount_rub" => BigDecimal("0"),
        "amount_mode" => "zeroing",
        "explicit_zero_target" => explicit_zero_target,
        "target_model_absent_in_excel" => false
      }
    end
  end

  def excel_absent_zeroing_enabled?
    return true if SourceModeResolver.xlsx_target_mode?(@analysis_session.effective_source_mode)

    value = @organization.settings.to_h["excel_target_zero_absent"]
    value == true || value.to_s == "true" || value.to_s == "1"
  end

  def existing_funding_keys(program_node)
    program_node.funding_lines.map do |line|
      [line.year, funding_source_value(line.source_type)]
    end.uniq
  end

  def funding_key(year, source_type)
    [year.to_i, funding_source_value(source_type)]
  end

  def new_amount_for_entry(old_amount, entry)
    mode = entry["amount_mode"].presence || "absolute"
    case mode
    when "delta_plus"
      old_amount + BigDecimal(entry.fetch("delta_rub").to_s)
    when "delta_minus"
      old_amount + BigDecimal(entry.fetch("delta_rub").to_s)
    when "zeroing"
      BigDecimal("0")
    else
      BigDecimal(entry.fetch("amount_rub").to_s)
    end
  end

  def entry_requires_confirmation?(entry, match_result)
    entry["amount_mode"].to_s.in?(%w[unknown transfer zeroing]) ||
      entry["transfer_pair"].present? ||
      entry["ocr_applied"].present? ||
      BigDecimal(entry["confidence"].to_s.presence || match_result.confidence.to_s) < @threshold ||
      match_result.source_reference["source_conflict"].present?
  rescue ArgumentError
    true
  end

  def initial_resolution_reason(requires_confirmation, entry, match_result)
    return nil unless requires_confirmation
    return "В источниках найден конфликт; будет применено правило приоритета источников." if match_result.source_reference["source_conflict"].present?
    return "Строка распознана через OCR и пройдет дополнительную проверку." if entry["ocr_applied"].present?
    return "Строка содержит перенос или особый тип изменения." if entry["transfer_pair"].present? || entry["amount_mode"].to_s.in?(%w[unknown transfer zeroing])

    "Строка будет дополнительно проверена агентом перед применением."
  end

  def primary_source_document
    @match_results.map(&:source_document).compact.uniq.first
  end

  def primary_excel_source_document
    @match_results.map(&:source_document).compact.detect(&:xlsx_finance?)
  end

  def excel_target_year_in_scope?(year)
    years = external_target_years
    years.blank? || years.include?(year.to_i)
  end

  def external_target_years
    @external_target_years ||= begin
      document = primary_excel_source_document
      payload = document&.parsed_payload || {}
      years = Array(payload["target_years"]).map(&:to_i)
      years += payload_years(payload["program_totals"])
      years += payload_years(payload["final_totals"])
      years += Array(payload["object_groups"]).flat_map { |group| funding_years(group["funding"]) }
      years += @match_results
        .select { |result| result.source_document&.xlsx_finance? }
        .flat_map { |result| Array(result.funding_entries).map { |entry| entry["year"].to_i } }
      years.reject(&:zero?).to_set
    end
  end

  def payload_years(raw)
    raw.to_h.keys.map(&:to_i).reject(&:zero?)
  end

  def funding_years(raw)
    raw.to_h.keys.filter_map do |key|
      year = key.to_s.split("::", 2).first.to_i
      year unless year.zero?
    end
  end

  def excel_target_mode?
    SourceModeResolver.xlsx_target_mode?(@analysis_session.effective_source_mode) ||
      @match_results.any? { |result| result.source_document&.xlsx_finance? }
  end

  def baseline_financial_nodes
    @baseline_financial_nodes ||= @program_version.program_nodes
      .includes(:funding_lines)
      .where(node_type: %w[object residual])
      .select { |node| node.funding_lines.any? && FinancialNodeClassifier.concrete_financial_node?(node) }
  end

  def funding_source_key(raw)
    FundingLine.source_types.key(funding_source_value(raw)) || raw.to_s
  end

  def funding_source_value(raw)
    FundingSourceCatalog.normalize(FundingLine.source_types.fetch(raw.to_s, raw.to_s), organization: @organization)
  end
end
