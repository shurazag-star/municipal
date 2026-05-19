require "set"

class ExternalSourceMatcher
  MatchResult = Struct.new(
    :candidate,
    :source_document,
    :program_node,
    :external_group,
    :funding_entries,
    :source_reference,
    :requires_user_confirmation,
    :confidence,
    :match_status,
    :agent_match_decision,
    keyword_init: true
  )

  def initialize(analysis_session:, source_document:, semantic_agent: :default)
    @analysis_session = analysis_session
    @source_document = source_document
    @program_version = analysis_session.program_version
    @organization = analysis_session.organization
    @threshold = BigDecimal(AgentSetting.for_organization!(@organization).match_confidence_threshold.to_s)
    @semantic_agent = semantic_agent == :default ? SemanticMatchAgent.new(
      organization: @organization,
      program_version: @program_version,
      user: analysis_session.user,
      analysis_session: analysis_session,
      source_document: source_document,
      source_mode: analysis_session.effective_source_mode
    ) : semantic_agent
  end

  def match!
    MatchCandidate.where(program_version: @program_version, source_document: @source_document).delete_all

    external_groups.map do |group|
      match = find_program_node(group)
      excel_row = excel_row_for(group)
      candidate = MatchCandidate.create!(
        program_version: @program_version,
        source_document: @source_document,
        program_node: match[:node],
        excel_row: excel_row,
        match_status: match[:status],
        confidence: BigDecimal(match[:confidence].to_s),
        reason: match[:reason],
        requires_user_confirmation: match[:requires_user_confirmation],
        user_decision: match[:requires_user_confirmation] ? "needs_confirmation" : "auto_matched"
      )
      match[:agent_match_decision]&.update!(match_candidate: candidate)
      source_reference = source_reference_for(group, excel_row)
      source_reference["agent_match_decision_id"] = match[:agent_match_decision].id if match[:agent_match_decision]

      MatchResult.new(
        candidate: candidate,
        source_document: @source_document,
        program_node: match[:node],
        external_group: group,
        funding_entries: group.fetch("funding_entries"),
        source_reference: source_reference,
        requires_user_confirmation: match[:requires_user_confirmation],
        confidence: BigDecimal(match[:confidence].to_s),
        match_status: match[:status],
        agent_match_decision: match[:agent_match_decision]
      )
    end
  end

  private

  def external_groups
    case @source_document.document_type
    when "xlsx_finance"
      excel_groups
    when "pdf_agreement"
      pdf_groups
    else
      []
    end
  end

  def excel_groups
    Array(payload["object_groups"]).map do |group|
      first_row = Array(group["rows"]).first || {}
      raw_values = first_row["raw_values"].presence || {}
      residual_context = residual_parent_context(first_row, group)
      object_name = group["object_name"].presence || first_row["object_name"].presence
      if object_name.blank? && group["status"] == "UNASSIGNED_RESIDUAL"
        object_name = residual_context["name"].presence ||
          raw_values["Наименование"].presence ||
          raw_values["Наименование объекта"].presence ||
          "Неуказанное направление"
      end
      object_name ||= group["group_key"].to_s.split("::").last
      object_code = group["object_code"].presence || first_row["object_code"]
	      group.merge(
	        "object_name" => object_name.to_s,
	        "object_code" => object_code.to_s,
	        "explicit_zero_target" => group["explicit_zero_target"].present? || first_row["explicit_zero_target"].present?,
	        "parent_activity_code" => first_row["parent_activity_code"],
        "residual_parent_name" => residual_context["name"],
        "residual_parent_row_number" => residual_context["row_number"],
        "residual_parent_classification_code" => residual_context["classification_code"],
        "funding_entries" => funding_entries_from_hash(group["funding"] || {})
      ).compact
	    end.select { |group| group["funding_entries"].any? || group["explicit_zero_target"] }
  end

  def pdf_groups
    Array(payload["changes"]).group_by { |change| [change["object_code"].to_s, normalize_name(change["object_name"])] }.map do |(_code, _name), changes|
      first = changes.first || {}
      {
        "group_key" => "pdf::#{first['object_code']}::#{first['object_name']}",
        "status" => "PDF_AGREEMENT_CHANGE",
        "object_name" => first["object_name"].to_s,
        "object_code" => first["object_code"].to_s,
        "event_name" => first["event_name"].to_s.presence,
        "rows" => [],
        "pdf_changes" => changes,
        "text_extraction_method" => payload["text_extraction_method"],
        "ocr_warnings" => Array(payload["warnings"]),
        "funding_entries" => changes.flat_map { |change| funding_entries_from_pdf_change(change) }.compact
      }
    end.select { |group| group["funding_entries"].any? }
  end

  def funding_entries_from_hash(funding)
    funding.filter_map do |key, amount|
      year, source_type = key.to_s.split("::", 2)
      next if year.blank?

      {
        "year" => year.to_i,
        "source_type" => normalize_source_type(source_type),
        "amount_rub" => BigDecimal(amount.to_s)
      }
    end
  end

  def funding_entries_from_pdf_change(change)
    amount_mode = change["amount_mode"].presence || "absolute"
    entries = if amount_mode == "transfer"
      transfer_entries_from_pdf_change(change)
    else
      [funding_entry_from_pdf_change(change)]
    end

    entries.compact
      .select { |entry| pdf_entry_in_program_period?(entry) }
      .map { |entry| entry.merge(ocr_metadata) }
  end

  def transfer_entries_from_pdf_change(change)
    from_year = change["from_year"].to_i
    to_year = change["to_year"].to_i
    return [funding_entry_from_pdf_change(change)] if from_year.zero? || to_year.zero?

    amount = transfer_amount(change)
    source_type = normalize_source_type(change["source_type"].presence || change["budget_source"])
    common = {
      "source_type" => source_type,
      "amount_rub" => amount,
      "from_year" => from_year,
      "to_year" => to_year,
      "confidence" => change["confidence"],
      "page_number" => change["page_number"].presence || change["page"],
      "transfer_pair" => true,
      "original_amount_mode" => "transfer"
    }

    [
      common.merge("year" => from_year, "amount_mode" => "delta_minus", "delta_rub" => (-amount.abs).to_s("F")),
      common.merge("year" => to_year, "amount_mode" => "delta_plus", "delta_rub" => amount.abs.to_s("F"))
    ]
  rescue ArgumentError
    []
  end

  def transfer_amount(change)
    amount = change["amount_rub"].presence ||
      change["new_amount_rub"].presence ||
      change["new_amount"].presence ||
      change["delta_rub"].presence ||
      "0"
    BigDecimal(amount.to_s)
  end

  def funding_entry_from_pdf_change(change)
    year = change["year"].to_i
    year = change["to_year"].to_i if year.zero? && change["to_year"].present?
    return nil if year.zero?
    amount_mode = change["amount_mode"].presence || "absolute"
    amount = change["amount_rub"].presence || change["new_amount_rub"].presence || change["new_amount"].presence || change["delta_rub"].presence || "0"

    {
      "year" => year,
      "source_type" => normalize_source_type(change["source_type"].presence || change["budget_source"]),
      "amount_rub" => BigDecimal(amount.to_s),
      "amount_mode" => amount_mode,
      "delta_rub" => change["delta_rub"],
      "from_year" => change["from_year"],
      "to_year" => change["to_year"],
      "confidence" => change["confidence"],
      "page_number" => change["page_number"].presence || change["page"],
      "evidence_text" => change["evidence_text"].presence || change["excerpt"]
    }
  rescue ArgumentError
    nil
  end

  def find_program_node(group)
    existing_parent_total = find_existing_parent_total_match(group)
    if existing_parent_total
      return exact_match(
        existing_parent_total,
        "MATCH_RESIDUAL_PARENT_TOTAL",
        "Остаточная строка Excel уже учтена в строке родительского мероприятия"
      )
    end

    residual_match = find_residual_program_node(group)
    if residual_match
      return exact_match(
        residual_match[:node],
        "MATCH_RESIDUAL_PARENT",
        "Остаточная строка Excel привязана к ближайшему смысловому родителю",
        residual_match[:confidence]
      )
    end

    code_match = find_by_code(group)
    return exact_match(code_match, "MATCH_EXACT_CODE", "Найдено точное совпадение по коду объекта") if code_match

    normalized_name = normalize_name(group["object_name"])
    exact_name_matches = candidate_object_nodes(group).select { |node| normalized_node_name(node) == normalized_name }
    if exact_name_matches.one?
      return exact_match(exact_name_matches.first, "MATCH_EXACT_NAME", "Найдено точное совпадение по наименованию")
    end
    if exact_name_matches.many?
      return uncertain_match(nil, "NEEDS_CONFIRMATION", "Найдено несколько объектов с таким наименованием", "0.5")
    end

    fuzzy_matches = ranked_fuzzy_matches(normalized_name, candidates: candidate_object_nodes(group))
    fuzzy = fuzzy_matches.first
    fuzzy_second = fuzzy_matches.second
    if fuzzy && fuzzy[:confidence] >= @threshold
      if fuzzy_second && ambiguous_fuzzy_match?(fuzzy, fuzzy_second)
        return uncertain_match(nil, "NEEDS_CONFIRMATION", "Найдено несколько похожих объектов, нужно уточнение", "0.5")
      end

      exact_match(fuzzy[:node], "MATCH_FUZZY_CONFIDENT", "Найдено похожее наименование", fuzzy[:confidence])
    else
      pdf_event_match = find_by_pdf_event_name(group)
      if pdf_event_match
        return exact_match(
          pdf_event_match[:node],
          "MATCH_PDF_EVENT_NAME",
          "PDF-приложение сопоставлено по наименованию мероприятия/результата",
          pdf_event_match[:confidence]
        )
      end

      semantic = semantic_match(group, normalized_name)
      return semantic if semantic

      uncertain_match(nil, group["status"] == "UNASSIGNED_RESIDUAL" ? "UNASSIGNED_RESIDUAL" : "MISSING_IN_DOCX", "Объект внешнего источника не найден в дереве программы", "0.0")
    end
  end

  def find_existing_parent_total_match(group)
    return nil unless group["status"] == "UNASSIGNED_RESIDUAL"
    return nil if group["parent_activity_code"].blank?

    parsed = parse_external_parent_code(group["parent_activity_code"])
    return nil unless parsed

    candidates = @program_version.program_nodes.where(node_type: %w[activity object])
    candidates = candidates.where(code: parsed[:activity_code]) if parsed[:activity_code].present?
    candidates = candidates.to_a.select { |node| activity_parent_candidate?(node) }
    candidates = candidates.select { |node| parent_activity_matches?(node, parsed) }.presence ||
      candidates.select { |node| parent_amounts_match?(node, group.fetch("funding_entries")) }
    matches = candidates.select { |node| parent_amounts_match?(node, group.fetch("funding_entries")) }
    return matches.first if matches.one?

    nil
  end

  def parent_activity_matches?(node, parsed)
    subprogram_matches = parsed[:subprogram_display].blank? || node_subprogram_display(node).to_s == parsed[:subprogram_display].to_s
    activity_matches = node.code.to_s == parsed[:activity_code].to_s || node.display_number.to_s == parsed[:activity_display].to_s

    subprogram_matches && activity_matches
  end

  def parent_amounts_match?(node, entries)
    tolerance = @tolerance || BigDecimal("0")
    entries = Array(entries)
    entry_keys = entries.map { |entry| funding_key(entry.fetch("year"), entry.fetch("source_type")) }.to_set
    entries.all? do |entry|
      (current_amount(node, entry.fetch("year"), entry.fetch("source_type")) - BigDecimal(entry.fetch("amount_rub").to_s)).abs <= tolerance
    end &&
      node.funding_lines.all? do |line|
        amount = BigDecimal(line.amount_rub.to_s)
        amount.abs <= tolerance || entry_keys.include?(funding_key(line.year, line.source_type))
      end
  end

  def current_amount(node, year, source_type)
    normalized_source = normalize_source_type(source_type)
    node.funding_lines.select do |line|
      line.year.to_i == year.to_i && normalize_source_type(line.source_type) == normalized_source
    end.sum(BigDecimal("0")) { |line| BigDecimal(line.amount_rub.to_s) }
  end

  def funding_key(year, source_type)
    [year.to_i, normalize_source_type(source_type)]
  end

  def semantic_match(group, normalized_name)
    return nil unless @semantic_agent
    return nil if deterministic_excel_target_group?(group)

    result = @semantic_agent.resolve(group: group, candidates: semantic_candidates(group, normalized_name))
    return nil unless result[:status] == "matched" && result[:node]

    exact_match(result[:node], "MATCH_SEMANTIC_AGENT", result[:reason], result[:confidence])
      .merge(agent_match_decision: result[:agent_match_decision])
  end

  def deterministic_excel_target_group?(group)
    return false unless @source_document.document_type == "xlsx_finance"
    return true if group["status"] == "UNASSIGNED_RESIDUAL" && group["parent_activity_code"].present?

    group["status"] == "GROUPED_OBJECT" &&
      group["parent_activity_code"].present? &&
      group["object_code"].present? &&
      group["object_code"].to_s != "0000000000.0000000000" &&
      group["object_name"].present?
  end

  def semantic_candidates(group, normalized_name)
    nodes = object_nodes.map do |node|
      { node: node, confidence: name_similarity(normalized_name, normalized_node_name(node)) }
    end.sort_by { |candidate| -candidate[:confidence] }.first(10).map { |candidate| candidate[:node] }
    SemanticCandidateBuilder.new(program_version: @program_version).build(
      group: group.merge("object_name" => group["object_name"].presence || normalized_name),
      source_document: @source_document
    ).presence || nodes
  end

  def exact_match(node, status, reason, confidence = "1.0")
    {
      node: node,
      status: status,
      confidence: confidence,
      reason: reason,
      requires_user_confirmation: false
    }
  end

  def uncertain_match(node, status, reason, confidence)
    {
      node: node,
      status: status,
      confidence: confidence,
      reason: reason,
      requires_user_confirmation: true
    }
  end

  def find_by_code(group)
    code = group["object_code"]
    return nil if code.blank?

    candidate_object_nodes(group).detect do |node|
      [node.code, node.external_code, node.metadata["object_code"], node.metadata["external_code"]].compact.map(&:to_s).include?(code.to_s)
    end
  end

  def find_by_pdf_event_name(group)
    return nil unless @source_document.pdf_agreement?

    normalized_event = normalize_name(group["event_name"])
    return nil if normalized_event.blank?

    candidates = object_nodes.filter_map do |node|
      normalized_node = normalized_node_name(node)
      next if normalized_node.blank?

      confidence = if normalized_node.include?(normalized_event)
        BigDecimal("0.95")
      else
        name_similarity(normalized_event, normalized_node)
      end
      next if confidence < BigDecimal("0.45")

      { node: node, confidence: confidence }
    end.sort_by { |candidate| -candidate[:confidence] }
    return nil if candidates.empty?

    top = candidates.first
    second = candidates.second
    return nil if second && second[:confidence] == top[:confidence]

    top
  end

  def best_fuzzy_match(normalized_name, candidates: object_nodes)
    ranked_fuzzy_matches(normalized_name, candidates: candidates).first
  end

  def ranked_fuzzy_matches(normalized_name, candidates: object_nodes)
    return [] if normalized_name.blank?

    candidates.map do |node|
      { node: node, confidence: name_similarity(normalized_name, normalized_node_name(node)) }
    end.sort_by { |candidate| [-candidate[:confidence], candidate[:node].id] }
  end

  def ambiguous_fuzzy_match?(top, second)
    return false unless top && second

    (top[:confidence] - second[:confidence]).abs <= BigDecimal("0.05")
  end

  def object_nodes
    @object_nodes ||= @program_version.program_nodes
      .where(node_type: %w[object residual])
      .to_a
      .select { |node| FinancialNodeClassifier.concrete_financial_node?(node) }
  end

  def candidate_object_nodes(group)
    parsed = parse_external_parent_code(group["parent_activity_code"])
    return object_nodes unless parsed

    object_nodes.select { |node| node_matches_parent_activity?(node, parsed) }
  end

  def structural_nodes
    @structural_nodes ||= @program_version.program_nodes
      .where(node_type: %w[object residual activity main_activity])
      .includes(:children)
      .to_a
  end

  def find_residual_program_node(group)
    return nil unless group["status"] == "UNASSIGNED_RESIDUAL"

    names = [
      group["residual_parent_name"],
      group["object_name"]
    ].compact.map(&:to_s).reject { |name| residual_placeholder_name?(name) }
    return nil if names.empty?

    match = names.filter_map { |name| best_structural_match(normalize_name(name)) }.max_by { |candidate| candidate[:confidence] }
    return nil unless match && match[:confidence] >= BigDecimal("0.45")

    leaf = application_leaf_for(match[:node])
    return nil unless leaf&.node_type.in?(%w[object residual])

    { node: leaf, confidence: match[:confidence] }
  end

  def best_structural_match(normalized_name)
    return nil if normalized_name.blank?

    structural_nodes.map do |node|
      { node: node, confidence: name_similarity(normalized_name, normalized_node_name(node)) }
    end.max_by { |candidate| candidate[:confidence] }
  end

  def application_leaf_for(node)
    return node if FinancialNodeClassifier.concrete_financial_node?(node)

    nil
  end

  def residual_parent_context(first_row, group)
    return {} unless group["status"] == "UNASSIGNED_RESIDUAL"

    row_number = first_row["row_number"].to_i
    return {} if row_number.zero?

    raw_values = first_row["raw_values"].presence || {}
    classification_code = raw_values["Классификация Код цел. программы.  Код мероприятия"].presence
    previous_rows = Array(payload["rows"])
      .select { |row| row["row_number"].to_i.positive? && row["row_number"].to_i < row_number }
      .reverse

    matched = if classification_code.present?
      previous_rows.find do |row|
        row.dig("raw_values", "Классификация Код цел. программы.  Код мероприятия").to_s == classification_code.to_s &&
          residual_context_name(row).present?
      end
    end
    matched ||= previous_rows.find { |row| residual_context_name(row).present? }
    return {} unless matched

    {
      "name" => residual_context_name(matched),
      "row_number" => matched["row_number"],
      "classification_code" => matched.dig("raw_values", "Классификация Код цел. программы.  Код мероприятия")
    }.compact
  end

  def residual_context_name(row)
    name = row.dig("raw_values", "Наименование").presence ||
      row.dig("raw_values", "Наименование объекта").presence ||
      row["object_name"].presence
    return nil if residual_placeholder_name?(name)

    name.to_s.squish.presence
  end

  def residual_placeholder_name?(name)
    normalized = normalize_name(name)
    normalized.blank? || normalized == "неуказанное направление"
  end

  def parse_external_parent_code(raw_code)
    digits = raw_code.to_s.gsub(/\D/, "")
    return nil if digits.length < 7 || !digits.start_with?("10")

    subprogram = digits[2].to_i
    main_activity = digits[3, 2].to_i
    activity = digits[5, 2].to_i
    return nil if subprogram.zero? || main_activity.zero? || activity.zero?

    {
      subprogram_display: subprogram.to_s,
      activity_code: format("%02d.%02d", main_activity, activity),
      activity_display: "#{main_activity}.#{activity}"
    }
  end

  def node_matches_parent_activity?(node, parsed)
    activity = activity_parent_candidate?(node) ? node : ancestor_of_type(node, "activity")
    return false unless activity

    subprogram = ancestor_of_type(activity, "subprogram")
    subprogram_matches = node_subprogram_display(activity).to_s == parsed[:subprogram_display].to_s
    activity_matches = activity.code.to_s == parsed[:activity_code].to_s ||
      normalize_name(activity.name).include?(normalize_name(parsed[:activity_code]))
    subprogram_matches && activity_matches
  end

  def activity_parent_candidate?(node)
    node.node_type == "activity" || activity_like_object_node?(node)
  end

  def activity_like_object_node?(node)
    node.node_type == "object" &&
      node.code.present? &&
      normalize_name(node.name).include?("мероприятие") &&
      !FinancialNodeClassifier.summary_row?(node)
  end

  def node_subprogram_display(node)
    ancestor_of_type(node, "subprogram")&.display_number.presence ||
      node.metadata.to_h["finance_table_index"].presence&.to_s
  end

  def ancestor_of_type(node, node_type)
    current = node.parent
    while current
      return current if current.node_type == node_type

      current = current.parent
    end
    nil
  end

  def normalized_node_name(node)
    normalize_name(node.normalized_name.presence || node.name)
  end

  def name_similarity(left, right)
    return BigDecimal("1.0") if left == right
    return BigDecimal("0.0") if left.blank? || right.blank?

    left_tokens = meaningful_name_tokens(left)
    right_tokens = meaningful_name_tokens(right)
    return BigDecimal("0.0") if left_tokens.empty? || right_tokens.empty?

    overlap = fuzzy_token_overlap(left_tokens, right_tokens)
    broader_coverage = BigDecimal(overlap.to_s) / BigDecimal([left_tokens.size, right_tokens.size].max.to_s)
    left_coverage = BigDecimal(overlap.to_s) / BigDecimal(left_tokens.size.to_s)

    [
      broader_coverage,
      left_coverage * BigDecimal("0.98")
    ].max
  end

  def meaningful_name_tokens(value)
    stopwords = %w[
      а в во г го д до за и к м мо на о об от по с со т у ул
      адрес адресу область московская муниципальная муниципальное муниципальной
      округ округа городского городская городское городском шатура
      в т ч пир
    ]
    normalize_name(value).split.uniq.reject do |token|
      token.length <= 1 || stopwords.include?(token)
    end
  end

  def fuzzy_token_overlap(left_tokens, right_tokens)
    used_right_indexes = {}

    left_tokens.count do |left_token|
      match_index = right_tokens.each_with_index.find do |right_token, index|
        !used_right_indexes[index] && tokens_match?(left_token, right_token)
      end&.last

      if match_index
        used_right_indexes[match_index] = true
        true
      else
        false
      end
    end
  end

  def tokens_match?(left_token, right_token)
    return true if left_token == right_token

    left_core = token_core(left_token)
    right_core = token_core(right_token)
    return true if left_core == right_core
    return true if left_core.length >= 5 && right_core.start_with?(left_core)
    return true if right_core.length >= 5 && left_core.start_with?(right_core)

    prefix = common_prefix_length(left_core, right_core)
    min_length = [left_core.length, right_core.length].min
    min_length >= 6 && prefix >= (min_length * 0.75).ceil
  end

  def token_core(token)
    suffixes = %w[
      ость ение ание ного ному ными ными ыми ими ами ями ого его ому ему
      ной ных них ых их ой ий ый ая ое ые ом ем ам ям ов ев
      а я ы и е о у ю
    ]
    suffix = suffixes.find { |candidate| token.length - candidate.length >= 3 && token.end_with?(candidate) }
    suffix ? token.delete_suffix(suffix) : token
  end

  def common_prefix_length(left, right)
    limit = [left.length, right.length].min
    index = 0
    index += 1 while index < limit && left[index] == right[index]
    index
  end

  def excel_row_for(group)
    return nil unless @source_document.xlsx_finance?

    first_row = Array(group["rows"]).first || {}
    row_number = first_row["row_number"].to_i
    return nil if row_number.zero?

    excel_row = @source_document.excel_rows.find_or_initialize_by(
      sheet_name: payload["sheet_name"].presence || "Результат",
      row_number: row_number
    )
    excel_row.assign_attributes(
      row_type: first_row["row_type"].presence || group["status"].presence || "UNKNOWN_ROW",
      raw_values: first_row["raw_values"].presence || {},
      normalized_values: {
        "parent_activity_code" => first_row["parent_activity_code"],
        "object_code" => group["object_code"],
        "object_name" => group["object_name"],
        "funding" => group["funding"]
      }.compact,
      parent_context: {
        "group_key" => group["group_key"],
        "group_status" => group["status"]
      }.compact
    )
    excel_row.save!
    excel_row
  end

  def source_reference_for(group, excel_row)
    reference = {
      "source_document_id" => @source_document.id,
      "filename" => @source_document.filename,
      "document_type" => @source_document.document_type,
      "group_key" => group["group_key"],
      "group_status" => group["status"],
	      "parent_activity_code" => group["parent_activity_code"],
	      "explicit_zero_target" => group["explicit_zero_target"],
      "residual_parent_name" => group["residual_parent_name"],
      "residual_parent_row_number" => group["residual_parent_row_number"],
      "residual_parent_classification_code" => group["residual_parent_classification_code"],
      "object_name" => group["object_name"],
      "event_name" => group["event_name"],
      "object_code" => group["object_code"]
    }.compact

    if excel_row
      reference.merge!(
        "sheet_name" => excel_row.sheet_name,
        "row_number" => excel_row.row_number
      )
    elsif @source_document.pdf_agreement?
      reference["text_extraction_method"] = payload["text_extraction_method"] if payload["text_extraction_method"].present?
      reference["ocr_applied"] = payload["text_extraction_method"] == "ocr"
      reference["ocr_warnings"] = Array(payload["warnings"]) if payload["warnings"].present?
      page_number = Array(group["pdf_changes"]).filter_map { |change| change["page_number"].presence || change["page"].presence }.first
      reference["page_number"] = page_number if page_number.present?
      evidence_text = Array(group["pdf_changes"]).filter_map { |change| change["evidence_text"].presence || change["excerpt"].presence }.first
      reference["evidence_text"] = evidence_text if evidence_text.present?
    end

    reference
  end

  def normalize_source_type(source_type)
    raw = source_type.to_s
    return "UNKNOWN" if raw.blank?

    aliases = {
      "federal" => "FEDERAL_BUDGET",
      "regional" => "REGIONAL_BUDGET",
      "local" => "LOCAL_BUDGET",
      "municipal" => "MUNICIPAL_BUDGET",
      "private" => "PRIVATE_FUNDS",
      "other" => "OTHER_SOURCE",
      "unknown" => "UNKNOWN"
    }
    return aliases.fetch(raw.downcase) if aliases.key?(raw.downcase)

    FundingSourceCatalog.normalize(FundingLine.source_types.fetch(raw, raw), organization: @organization)
  end

  def ocr_metadata
    method = payload["text_extraction_method"].presence
    return {} unless method == "ocr"

    {
      "text_extraction_method" => method,
      "ocr_applied" => true,
      "ocr_warnings" => Array(payload["warnings"])
    }
  end

  def pdf_entry_in_program_period?(entry)
    return true unless @source_document.pdf_agreement?

    start_year = @program_version.municipal_program&.period_start_year
    end_year = @program_version.municipal_program&.period_end_year
    return true if start_year.blank? || end_year.blank?

    entry["year"].to_i.between?(start_year.to_i, end_year.to_i)
  end

  def normalize_name(value)
    value.to_s.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def payload
    @payload ||= @source_document.parsed_payload || {}
  end
end
