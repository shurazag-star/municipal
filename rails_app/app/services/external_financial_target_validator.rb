class ExternalFinancialTargetValidator
  def initialize(generated_docx_payload:, external_target_payload:, document_type:, tolerance:, organization: nil)
    @generated_docx_payload = generated_docx_payload || {}
    @external_target_payload = external_target_payload || {}
    @document_type = document_type
    @tolerance = BigDecimal(tolerance.to_s)
    @organization = organization
  end

  def validate
    errors = []
    warnings = []
    passport = compare_year_totals(errors)
    passport_sources = compare_source_totals(errors, warnings)
    total_columns = compare_total_columns(errors)
    numeric_labels = numeric_object_labels
    if numeric_labels.any?
      errors << {
        "code" => "numeric_object_label",
        "message" => "В сгенерированном дереве найдены числовые названия объектов",
        "labels" => numeric_labels
      }
    end

    {
      "status" => errors.any? ? "invalid" : "valid",
      "document_type" => @document_type,
      "errors" => errors,
      "warnings" => warnings,
      "passport" => passport,
      "passport_sources" => passport_sources,
      "total_columns" => total_columns
    }
  end

  private

  def compare_year_totals(errors)
    expected = expected_year_totals
    actual = normalized_year_money_hash(@generated_docx_payload["passport_totals_by_year"] || {})
    passport = {}

    errors << { "code" => "external_target_totals_missing", "message" => "В Excel-цели не найдены итоговые суммы программы" } if expected.blank?
    errors << { "code" => "external_passport_totals_missing", "message" => "В сформированном DOCX не найдены паспортные итоги" } if actual.blank?

    expected.each do |year, expected_amount|
      actual_amount = actual[year]
      passport[year.to_s] = comparison_row(expected_amount, actual_amount)
      if actual_amount.nil?
        errors << { "code" => "external_passport_total_missing", "year" => year.to_s, "message" => "В паспорте DOCX нет суммы за #{year} для сравнения с Excel" }
        next
      end

      delta = actual_amount - expected_amount
      next if delta.abs <= @tolerance

      errors << {
        "code" => "external_passport_total_mismatch",
        "year" => year.to_s,
        "expected_rub" => money(expected_amount),
        "actual_rub" => money(actual_amount),
        "delta_rub" => money(delta),
        "message" => "Паспортная сумма за #{year} не совпадает с Excel-целью"
      }
    end
    passport
  end

  def compare_source_totals(errors, warnings)
    expected = expected_source_year_totals
    actual = normalized_source_money_hash(@generated_docx_payload["passport_amounts"] || {})
    passport_sources = {}

    if expected.blank?
      warnings << { "code" => "external_source_totals_missing", "message" => "В Excel-цели не удалось вывести суммы по источникам" }
      return passport_sources
    end

    expected.each do |(year, source_type), expected_amount|
      actual_amount = actual[[year, source_type]]
      key = "#{year}::#{source_type}"
      passport_sources[key] = comparison_row(expected_amount, actual_amount)
      if actual_amount.nil?
        errors << { "code" => "external_passport_source_missing", "year" => year.to_s, "source_type" => source_type, "message" => "В паспорте DOCX нет суммы за #{year} по источнику #{source_type}" }
        next
      end

      delta = actual_amount - expected_amount
      next if delta.abs <= @tolerance

      errors << {
        "code" => "external_passport_source_mismatch",
        "year" => year.to_s,
        "source_type" => source_type,
        "expected_rub" => money(expected_amount),
        "actual_rub" => money(actual_amount),
        "delta_rub" => money(delta),
        "message" => "Паспортная сумма за #{year} по источнику #{source_type} не совпадает с Excel-целью"
      }
    end
    passport_sources
  end

  def compare_total_columns(errors)
    result = {}
    source_year_totals = normalized_source_money_hash(@generated_docx_payload["passport_amounts"] || {})
    source_columns = normalized_source_total_column_hash(@generated_docx_payload["passport_source_total_column_amounts"] || {})
    source_sums = source_year_totals.each_with_object({}) do |((_year, source_type), amount), sums|
      sums[source_type] = (sums[source_type] || BigDecimal("0")) + amount
    end

    if source_sums.any? && source_columns.blank?
      errors << { "code" => "passport_source_total_column_missing", "message" => "В паспорте DOCX не найдены итоговые колонки по источникам" }
    end
    source_sums.each do |source_type, expected_sum|
      column_amount = source_columns[source_type]
      result[source_type] = comparison_row(expected_sum, column_amount)
      next if column_amount.nil?

      delta = column_amount - expected_sum
      next if delta.abs <= @tolerance

      errors << {
        "code" => "passport_source_total_column_mismatch",
        "source_type" => source_type,
        "expected_rub" => money(expected_sum),
        "actual_rub" => money(column_amount),
        "delta_rub" => money(delta),
        "message" => "Колонка Всего в паспорте по источнику #{source_type} не равна сумме годовых колонок"
      }
    end

    year_totals = normalized_year_money_hash(@generated_docx_payload["passport_totals_by_year"] || {})
    expected_grand = year_totals.values.sum(BigDecimal("0"))
    raw_grand = @generated_docx_payload["passport_grand_total_column_amount"]
    if year_totals.any? && raw_grand.blank?
      errors << { "code" => "passport_grand_total_column_missing", "message" => "В паспорте DOCX не найдена итоговая колонка Всего" }
    elsif raw_grand.present?
      grand = BigDecimal(raw_grand.to_s)
      result["TOTAL"] = comparison_row(expected_grand, grand)
      delta = grand - expected_grand
      if delta.abs > @tolerance
        errors << {
          "code" => "passport_grand_total_column_mismatch",
          "expected_rub" => money(expected_grand),
          "actual_rub" => money(grand),
          "delta_rub" => money(delta),
          "message" => "Итоговая колонка Всего в паспорте не равна сумме годовых колонок"
        }
      end
    end

    result
  end

  def expected_year_totals
    normalized_year_money_hash(@external_target_payload["final_totals"].presence || @external_target_payload["program_totals"] || {})
  end

  def expected_source_year_totals
    direct = @external_target_payload["source_totals"]
    return normalized_source_money_hash(direct) if direct.present?

    Array(@external_target_payload["object_groups"]).each_with_object({}) do |group, totals|
      (group["funding"] || {}).each do |raw_key, raw_amount|
        year, source_type = parse_funding_key(raw_key)
        next if year.blank? || source_type.blank?

        key = [year, source_type]
        totals[key] = (totals[key] || BigDecimal("0")) + BigDecimal(raw_amount.to_s)
      end
    end
  end

  def normalized_year_money_hash(raw)
    raw.each_with_object({}) do |(year, amount), result|
      result[year.to_i] = BigDecimal(amount.to_s)
    end
  end

  def normalized_source_money_hash(raw)
    raw.each_with_object({}) do |(key, amount), result|
      year, source_type = parse_funding_key(key)
      next if year.blank? || source_type.blank?

      result[[year, source_type]] = BigDecimal(amount.to_s)
    end
  end

  def normalized_source_total_column_hash(raw)
    raw.each_with_object({}) do |(source_type, amount), result|
      result[funding_source_value(source_type)] = BigDecimal(amount.to_s)
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

  def numeric_object_labels
    Array(@generated_docx_payload["nodes"]).filter_map do |node|
      next unless node["node_type"].to_s.in?(%w[object residual])

      name = node["name"].to_s.strip
      numeric_label?(name) ? name : nil
    end
  end

  def numeric_label?(value)
    value.to_s.strip.match?(/\A[-+]?\d+(?:[.,]\d+)?\z/)
  end

  def comparison_row(expected_amount, actual_amount)
    delta = actual_amount ? actual_amount - expected_amount : nil
    {
      "expected_rub" => money(expected_amount),
      "actual_rub" => actual_amount ? money(actual_amount) : nil,
      "delta_rub" => delta ? money(delta) : nil
    }
  end

  def money(amount)
    format("%.2f", BigDecimal(amount.to_s))
  end

  def funding_source_value(raw)
    FundingSourceCatalog.normalize(FundingLine.source_types.fetch(raw.to_s, raw.to_s), organization: @organization)
  end
end
