class SemanticCandidateBuilder
  DEFAULT_LIMIT = 10

  def initialize(program_version:, limit: DEFAULT_LIMIT)
    @program_version = program_version
    @limit = limit
  end

  def build(group:, source_document: nil)
    normalized_name = normalize_name(group["object_name"].presence || group["event_name"])
    nodes = candidate_nodes(group)

    scored = nodes.map do |node|
      candidate_snapshot(node, normalized_name, source_document)
    end

    scored
      .sort_by { |candidate| [-BigDecimal(candidate["similarity_score"].to_s), candidate["display_number"].to_s, candidate["program_node_id"].to_i] }
      .first(@limit)
  end

  private

  def candidate_nodes(group)
    parsed = parse_external_parent_code(group["parent_activity_code"])
    nodes = @program_version.program_nodes.includes(:parent, :funding_lines).where(node_type: %w[object residual]).to_a
    return nodes unless parsed

    filtered = nodes.select { |node| node_matches_parent_activity?(node, parsed) }
    filtered.presence || nodes
  end

  def candidate_snapshot(node, normalized_external_name, source_document)
    {
      "program_node_id" => node.id,
      "node_type" => node.node_type,
      "display_number" => node.display_number,
      "name" => node.name,
      "parent_name" => node.parent&.name,
      "path" => hierarchy_path(node),
      "similarity_score" => format("%.4f", name_similarity(normalized_external_name, normalize_name(node.normalized_name.presence || node.name))),
      "funding_years" => node.funding_lines.map(&:year).compact.uniq.sort,
      "funding_sources" => node.funding_lines.map { |line| funding_source_value(line.source_type, source_document) }.uniq.sort
    }.compact
  end

  def hierarchy_path(node)
    path = []
    current = node
    while current
      label = [current.display_number, current.name].compact_blank.join(" ")
      path.unshift(label.presence || current.name)
      current = current.parent
    end
    path
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
    activity = ancestor_of_type(node, "activity")
    return false unless activity

    subprogram = ancestor_of_type(activity, "subprogram")
    subprogram_matches = subprogram&.display_number.to_s == parsed[:subprogram_display].to_s
    activity_matches = activity.code.to_s == parsed[:activity_code].to_s ||
      normalize_name(activity.name).include?(normalize_name(parsed[:activity_code])) ||
      activity.display_number.to_s == parsed[:activity_display].to_s
    subprogram_matches && activity_matches
  end

  def ancestor_of_type(node, node_type)
    current = node.parent
    while current
      return current if current.node_type == node_type

      current = current.parent
    end
    nil
  end

  def name_similarity(left, right)
    return BigDecimal("1.0") if left == right
    return BigDecimal("0.0") if left.blank? || right.blank?

    left_tokens = meaningful_tokens(left)
    right_tokens = meaningful_tokens(right)
    return BigDecimal("0.0") if left_tokens.empty? || right_tokens.empty?

    overlap = left_tokens.count { |token| right_tokens.any? { |right_token| tokens_match?(token, right_token) } }
    BigDecimal(overlap.to_s) / BigDecimal([left_tokens.size, right_tokens.size].max.to_s)
  end

  def meaningful_tokens(value)
    stopwords = %w[
      а в во г го д до за и к м мо на о об от по с со т у ул
      адрес адресу область московская муниципальная муниципальное муниципальной
      округ округа городского городская городское городском
      в т ч пир
    ]
    normalize_name(value).split.uniq.reject { |token| token.length <= 1 || stopwords.include?(token) }
  end

  def tokens_match?(left, right)
    return true if left == right

    left.length >= 5 && right.start_with?(left) || right.length >= 5 && left.start_with?(right)
  end

  def normalize_name(value)
    value.to_s.downcase.tr("Ёё", "ее").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def funding_source_value(raw, source_document)
    organization = source_document&.organization || @program_version.municipal_program&.organization
    FundingSourceCatalog.normalize(FundingLine.source_types.fetch(raw.to_s, raw.to_s), organization: organization)
  end
end
