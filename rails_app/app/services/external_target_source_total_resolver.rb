class ExternalTargetSourceTotalResolver
  ADJUSTMENT_SOURCE_PRIORITY = %w[LOCAL_BUDGET MUNICIPAL_BUDGET OTHER_SOURCE REGIONAL_BUDGET FEDERAL_BUDGET EXTRABUDGETARY].freeze

  def initialize(payload:, organization:, tolerance:)
    @payload = payload || {}
    @organization = organization
    @tolerance = BigDecimal(tolerance.to_s)
  end

  def source_year_totals
    totals = direct_source_totals
    totals = source_totals_from_object_groups if totals.blank?
    totals = program_total_row_source_totals if totals.blank?
    reconcile_to_control_year_totals(totals)
  rescue ArgumentError
    {}
  end

  private

  def direct_source_totals
    normalized_source_money_hash(@payload["source_totals"] || {})
  end

  def source_totals_from_object_groups
    Array(@payload["object_groups"]).each_with_object({}) do |group, result|
      source_totals_from_funding_hash(group["funding"]).each do |key, amount|
        result[key] = (result[key] || BigDecimal("0")) + amount
      end
    end
  end

  def program_total_row_source_totals
    program_total_row = Array(@payload["rows"]).detect do |row|
      row["row_type"].to_s == "PROGRAM_TOTAL_ROW" && row["funding"].present?
    end
    source_totals_from_funding_hash(program_total_row&.fetch("funding", nil) || {})
  end

  def reconcile_to_control_year_totals(totals)
    return totals if totals.blank?

    control_totals = normalized_year_money_hash(@payload["final_totals"].presence || @payload["program_totals"] || {})
    return totals if control_totals.blank?

    result = totals.dup
    totals_by_year = totals.each_with_object(Hash.new(BigDecimal("0"))) do |((year, _source_type), amount), sums|
      sums[year] += amount
    end
    control_totals.each do |year, expected_amount|
      delta = expected_amount - totals_by_year.fetch(year, BigDecimal("0"))
      next if delta.abs <= @tolerance

      key = adjustment_key_for(result, year)
      result[key] = (result[key] || BigDecimal("0")) + delta
    end
    result
  end

  def adjustment_key_for(totals, year)
    present_sources = totals.keys.select { |candidate_year, _source_type| candidate_year == year }.map(&:last)
    source_type = ADJUSTMENT_SOURCE_PRIORITY.detect { |candidate| present_sources.include?(funding_source_value(candidate)) }
    [year, source_type || "LOCAL_BUDGET"]
  end

  def normalized_year_money_hash(raw)
    raw.to_h.each_with_object({}) do |(year, amount), result|
      year = year.to_i
      next if year.zero?

      result[year] = BigDecimal(amount.to_s)
    end
  end

  def normalized_source_money_hash(raw)
    raw.to_h.each_with_object({}) do |(key, amount), result|
      year, source_type = parse_funding_key(key)
      next if year.blank? || source_type.blank?

      result[[year, source_type]] = BigDecimal(amount.to_s)
    end
  end

  def source_totals_from_funding_hash(funding)
    (funding || {}).to_h.each_with_object({}) do |(key, amount), result|
      year, source_type = parse_funding_key(key)
      next if year.blank? || source_type.blank?

      result[[year, source_type]] = (result[[year, source_type]] || BigDecimal("0")) + BigDecimal(amount.to_s)
    end
  end

  def parse_funding_key(raw_key)
    key = raw_key.to_s
    if (match = key.match(/\A(20\d{2})::(.+)\z/))
      [match[1].to_i, funding_source_value(match[2])]
    elsif (match = key.match(/\A\[(20\d{2}),\s*['"]?([^'"\]]+)['"]?\]\z/))
      [match[1].to_i, funding_source_value(match[2])]
    else
      [nil, nil]
    end
  end

  def funding_source_value(raw)
    FundingSourceCatalog.normalize(FundingLine.source_types.fetch(raw.to_s, raw.to_s), organization: @organization)
  end
end
