require "tempfile"

class PostExportDocxValidator
  def initialize(
    program_version:,
    generated_docx_attachment: nil,
    generated_docx_bytes: nil,
    external_target_document: nil,
    parser_client: ParserWorkerClient.new,
    visual_renderer: DocxVisualRenderer.new
  )
    @program_version = program_version
    @generated_docx_attachment = generated_docx_attachment
    @generated_docx_bytes = generated_docx_bytes
    @external_target_document = external_target_document
    @parser_client = parser_client
    @visual_renderer = visual_renderer
    @tolerance = BigDecimal(AgentSetting.for_organization!(@program_version.municipal_program.organization).money_tolerance_rub.to_s)
  end

  def validate
    docx_bytes = generated_docx_bytes
    if docx_bytes.blank?
      return invalid_result([{ "code" => "generated_docx_missing", "message" => "Сформированный DOCX не прикреплен" }])
    end

    payload = parse_generated_docx(docx_bytes)
    visual_render = @visual_renderer&.render(docx_bytes: docx_bytes)
    compare_payload(payload, visual_render)
  rescue StandardError => error
    invalid_result(
      [
        {
          "code" => "post_export_parse_failed",
          "message" => "Не удалось проверить сформированный DOCX: #{error.message}"
        }
      ]
    )
  end

  private

  def generated_docx_bytes
    @generated_docx_bytes || @generated_docx_attachment&.download
  end

  def parse_generated_docx(docx_bytes)
    Tempfile.create(["generated_docx_validation", ".docx"]) do |file|
      file.binmode
      file.write(docx_bytes)
      file.flush
      @parser_client.parse_docx_path(file.path)
    end
  end

  def compare_payload(payload, visual_render)
    errors = []
    warnings = []
    expected = target_year_totals
    actual = normalized_money_hash(payload["passport_totals_by_year"] || {})
    expected_sources = target_source_year_totals
    actual_sources = normalized_source_money_hash(payload["passport_amounts"] || {})
    external_target = external_target_validation(payload)
    object_funding = object_funding_validation(payload)
    aggregate_funding = aggregate_funding_validation(payload)

    warnings << { "code" => "target_totals_missing", "message" => "В целевой модели нет итоговых сумм по годам" } if expected.blank?
    if actual.blank?
      errors << { "code" => "passport_totals_missing", "message" => "В сформированном DOCX не найдены паспортные итоги" }
    end

    passport = {}
    expected.each do |year, expected_amount|
      actual_amount = actual[year]
      if actual_amount.nil?
        errors << { "code" => "passport_total_missing", "year" => year.to_s, "message" => "В паспорте DOCX нет суммы за #{year}" }
        passport[year.to_s] = passport_row(expected_amount, nil)
        next
      end

      delta = actual_amount - expected_amount
      passport[year.to_s] = passport_row(expected_amount, actual_amount)
      next if delta.abs <= @tolerance

      errors << {
        "code" => "passport_total_mismatch",
        "year" => year.to_s,
        "expected_rub" => money(expected_amount),
        "actual_rub" => money(actual_amount),
        "delta_rub" => money(delta),
        "message" => "Паспортная сумма за #{year} не совпадает с целевой моделью"
      }
    end

    passport_sources = {}
    expected_sources.each do |(year, source_type), expected_amount|
      actual_amount = actual_sources[[year, source_type]]
      key = "#{year}::#{source_type}"
      if actual_amount.nil?
        passport_sources[key] = passport_row(expected_amount, nil)
        next
      end

      delta = actual_amount - expected_amount
      passport_sources[key] = passport_row(expected_amount, actual_amount)
      next if delta.abs <= @tolerance

      errors << {
        "code" => "passport_source_mismatch",
        "year" => year.to_s,
        "source_type" => source_type,
        "expected_rub" => money(expected_amount),
        "actual_rub" => money(actual_amount),
        "delta_rub" => money(delta),
        "message" => "Паспортная сумма за #{year} по источнику #{source_type} не совпадает с целевой моделью"
      }
    end

    if visual_render.present? && visual_render["status"] != "valid"
      errors << {
        "code" => "visual_render_failed",
        "message" => "Визуальная проверка DOCX не пройдена",
        "visual_render_status" => visual_render["status"]
      }
    end
    if external_target.present?
      errors.concat(Array(external_target["errors"]))
      warnings.concat(Array(external_target["warnings"]))
    end
    errors.concat(Array(object_funding["errors"]))
    errors.concat(Array(aggregate_funding["errors"]))

    status =
      if errors.any?
        "invalid"
      elsif warnings.any?
        "valid_with_warnings"
      else
        "valid"
      end

    {
      "status" => status,
      "errors" => errors,
      "warnings" => warnings,
      "passport" => passport,
      "passport_sources" => passport_sources,
      "object_funding" => object_funding.except("errors"),
      "aggregate_funding" => aggregate_funding.except("errors"),
      "external_target" => external_target,
      "visual_render" => visual_render,
      "money_tolerance_rub" => money(@tolerance)
    }
  end

  def invalid_result(errors)
    {
      "status" => "invalid",
      "errors" => errors,
      "warnings" => [],
      "passport" => {},
      "passport_sources" => {},
      "object_funding" => { "checked_count" => 0 },
      "aggregate_funding" => { "checked_count" => 0 },
      "external_target" => nil,
      "visual_render" => nil,
      "money_tolerance_rub" => money(@tolerance)
    }
  end

  def external_target_validation(payload)
    return nil unless @external_target_document&.xlsx_finance?

	    ExternalFinancialTargetValidator.new(
	      generated_docx_payload: payload,
	      external_target_payload: @external_target_document.parsed_payload || {},
	      document_type: @external_target_document.document_type,
	      tolerance: @tolerance,
	      organization: @program_version.municipal_program.organization
	    ).validate
  end

  def object_funding_validation(payload)
    expected = expected_object_funding_amounts
    actual = actual_object_funding_amounts(payload)
    errors = []
    checked_count = 0

    expected.each do |key, expected_amount|
      actual_amount = actual[key]
      next if expected_amount.abs <= object_money_tolerance && actual_amount.nil?

      actual_amount ||= BigDecimal("0")
      checked_count += 1
      delta = actual_amount - expected_amount
      next if delta.abs <= object_money_tolerance

      object_key, year, source_type = key
      object_name = object_label_for_key(object_key)
      errors << {
        "code" => "object_funding_mismatch",
        "object_name" => object_name,
        "display_number" => object_key.fetch(:display_number),
        "table_index" => object_key.fetch(:table_index),
        "year" => year.to_s,
        "source_type" => source_type,
        "expected_rub" => money(expected_amount),
        "actual_rub" => money(actual_amount),
        "delta_rub" => money(delta),
        "message" => "Сумма по объекту «#{object_name}» за #{year} по источнику #{source_type} не совпадает с целевой моделью"
      }
    end

    {
      "checked_count" => checked_count,
      "errors_count" => errors.size,
      "errors" => errors
    }
  end

  def aggregate_funding_validation(payload)
    expected = expected_aggregate_funding_amounts
    actual = actual_aggregate_funding_amounts(payload)
    errors = []
    checked_count = 0

    expected.each do |key, expected_amount|
      actual_amount = actual[key]
      next if expected_amount.abs <= object_money_tolerance && actual_amount.nil?

      actual_amount ||= BigDecimal("0")
      checked_count += 1
      delta = actual_amount - expected_amount
      next if delta.abs <= object_money_tolerance

      node_key, year, source_type = key
      node_name = aggregate_labels_by_key[node_key].presence || node_key.fetch(:normalized_name)
      errors << {
        "code" => "aggregate_funding_mismatch",
        "node_name" => node_name,
        "node_type" => node_key.fetch(:node_type),
        "display_number" => node_key.fetch(:display_number),
        "table_index" => node_key.fetch(:table_index),
        "row_index" => aggregate_row_indexes_by_key[node_key],
        "year" => year.to_s,
        "source_type" => source_type,
        "expected_rub" => money(expected_amount),
        "actual_rub" => money(actual_amount),
        "delta_rub" => money(delta),
        "message" => "Итоговая строка «#{node_name}» за #{year} по источнику #{source_type} не совпадает с пересчитанной моделью"
      }
    end

    {
      "checked_count" => checked_count,
      "errors_count" => errors.size,
      "errors" => errors
    }
  end

  def target_year_totals
    @target_year_totals ||= root_total_nodes.flat_map(&:funding_lines).each_with_object({}) do |line, totals|
      totals[line.year] = (totals[line.year] || BigDecimal("0")) + BigDecimal(line.amount_rub.to_s)
    end
  end

  def target_source_year_totals
    @target_source_year_totals ||= root_total_nodes.flat_map(&:funding_lines).each_with_object({}) do |line, totals|
      key = [line.year, funding_source_value(line.source_type)]
      totals[key] = (totals[key] || BigDecimal("0")) + BigDecimal(line.amount_rub.to_s)
    end
  end

  def root_total_nodes
    program_node = @program_version.program_nodes.includes(:funding_lines).find_by(node_type: "program")
    return [program_node] if program_node

    nodes = @program_version.program_nodes.includes(:funding_lines).to_a
    by_id = nodes.index_by(&:id)
    nodes.select { |node| node.parent_id.blank? || !by_id.key?(node.parent_id) }
  end

  def expected_object_funding_amounts
    @expected_object_funding_amounts ||= @program_version.program_nodes
      .includes(:funding_lines)
      .where(node_type: %w[object residual])
      .each_with_object(Hash.new(BigDecimal("0"))) do |node, result|
        next if node.metadata&.dig("docx_virtual_residual")

        object_key = object_key_for_node(node)
        next unless object_key
        next unless finance_display_number?(object_key.fetch(:display_number))
        object_labels_by_key[object_key] ||= node.name.to_s

        node.funding_lines.each do |line|
          key = [object_key, line.year.to_i, funding_source_value(line.source_type)]
          result[key] += BigDecimal(line.amount_rub.to_s)
        end
      end
  end

  def expected_aggregate_funding_amounts
    @expected_aggregate_funding_amounts ||= @program_version.program_nodes
      .includes(:funding_lines)
      .each_with_object(Hash.new(BigDecimal("0"))) do |node, result|
        next unless aggregate_validation_node?(node)

        node_key = aggregate_key_for_node(node)
        next unless node_key

        aggregate_labels_by_key[node_key] ||= node.name.to_s
        aggregate_row_indexes_by_key[node_key] ||= node.source_row_index
        if aggregate_total_only_node?(node)
          node.funding_lines.group_by(&:year).each do |year, lines|
            key = [node_key, year.to_i, "TOTAL"]
            result[key] += lines.sum(BigDecimal("0")) { |line| BigDecimal(line.amount_rub.to_s) }
          end
        else
          node.funding_lines.each do |line|
            key = [node_key, line.year.to_i, funding_source_value(line.source_type)]
            result[key] += BigDecimal(line.amount_rub.to_s)
          end
        end
      end
  end

  def actual_object_funding_amounts(payload)
    nodes_by_stable_key = Array(payload["nodes"]).index_by { |node| node["stable_key"] }
    Array(payload["funding_lines"]).each_with_object(Hash.new(BigDecimal("0"))) do |line, result|
      node = nodes_by_stable_key[line["node_stable_key"]]
      next unless node
      next unless node["node_type"].to_s.in?(%w[object residual activity])

      object_key = object_key_for_payload_node(node)
      next unless object_key

      year = line["year"].to_i
      source_type = funding_source_value(line["source_type"])
      next if year.zero? || source_type.blank?

      key = [object_key, year, source_type]
      result[key] += BigDecimal(line["amount_rub"].to_s)
    rescue ArgumentError
      next
    end
  end

  def actual_aggregate_funding_amounts(payload)
    nodes_by_stable_key = Array(payload["nodes"]).index_by { |node| node["stable_key"] }
    result = Hash.new(BigDecimal("0"))
    Array(payload["nodes"]).each do |node|
      next unless aggregate_validation_payload_node?(node)
      next unless aggregate_total_only_payload_node?(node)

      node_key = aggregate_key_for_payload_node(node)
      next unless node_key

      metadata = node["metadata"] || {}
      unit = metadata["docx_unit_in_document"].presence || "thousand_rub"
      (metadata["docx_year_raw_values"] || {}).each do |year, raw_amount|
        amount = parse_document_money(raw_amount, unit)
        next unless amount

        result[[node_key, year.to_i, "TOTAL"]] += amount
      end
    end

    Array(payload["funding_lines"]).each_with_object(result) do |line, aggregate_result|
      node = nodes_by_stable_key[line["node_stable_key"]]
      next unless node
      next unless aggregate_validation_payload_node?(node)
      next if aggregate_total_only_payload_node?(node)

      node_key = aggregate_key_for_payload_node(node)
      next unless node_key

      year = line["year"].to_i
      source_type = funding_source_value(line["source_type"])
      next if year.zero? || source_type.blank?

      key = [node_key, year, source_type]
      aggregate_result[key] += BigDecimal(line["amount_rub"].to_s)
    rescue ArgumentError
      next
    end
  end

  def aggregate_validation_node?(node)
    return false if node.metadata&.dig("docx_virtual_residual")
    return true if FinancialNodeClassifier.summary_row?(node)

    node.node_type.to_s.in?(%w[program subprogram main_activity activity]) &&
      node.metadata.to_h["docx_year_cell_indexes"].present?
  end

  def aggregate_validation_payload_node?(node)
    node_type = node["node_type"].to_s
    return true if payload_summary_row?(node)

    node_type.in?(%w[program subprogram main_activity activity]) &&
      (node["metadata"] || {})["docx_year_raw_values"].present?
  end

  def aggregate_total_only_node?(node)
    !FinancialNodeClassifier.summary_row?(node) || node.funding_lines.empty?
  end

  def aggregate_total_only_payload_node?(node)
    !payload_summary_row?(node)
  end

  def payload_summary_row?(node)
    metadata = node["metadata"] || {}
    metadata["docx_summary_row"].to_s == "true" ||
      metadata["summary_row"].to_s == "true" ||
      FinancialNodeClassifier.total_marker?([node["display_number"], node["name"], node["code"]].compact.join(" "))
  end

  def object_key_for_node(node)
    table_index = node.source_table_index
    display_number = node.display_number.to_s.strip
    normalized_name = normalize_name(node.name)
    return nil if table_index.blank? || display_number.blank? || normalized_name.blank?

    {
      table_index: table_index.to_i,
      display_number: display_number,
      normalized_name: normalized_name
    }
  end

  def object_key_for_payload_node(node)
    table_index = node["source_table_index"]
    display_number = node["display_number"].to_s.strip
    name = node["name"].to_s
    normalized_name = normalize_name(name)
    return nil if table_index.blank? || display_number.blank? || normalized_name.blank?

    {
      table_index: table_index.to_i,
      display_number: display_number,
      normalized_name: normalized_name
    }
  end

  def aggregate_key_for_node(node)
    table_index = node.source_table_index
    row_index = node.source_row_index
    display_number = node.display_number.to_s.strip
    normalized_name = normalize_name(node.name)
    return nil if table_index.blank? || row_index.blank? || normalized_name.blank?

    {
      node_type: aggregate_node_type(node),
      table_index: table_index.to_i,
      code: node.code.to_s,
      display_number: display_number,
      normalized_name: normalized_name
    }
  end

  def aggregate_key_for_payload_node(node)
    table_index = node["source_table_index"]
    row_index = node["source_row_index"]
    display_number = node["display_number"].to_s.strip
    normalized_name = normalize_name(node["name"])
    return nil if table_index.blank? || row_index.blank? || normalized_name.blank?

    {
      node_type: aggregate_payload_node_type(node),
      table_index: table_index.to_i,
      code: node["code"].to_s,
      display_number: display_number,
      normalized_name: normalized_name
    }
  end

  def aggregate_node_type(node)
    FinancialNodeClassifier.summary_row?(node) ? "summary" : node.node_type.to_s
  end

  def aggregate_payload_node_type(node)
    payload_summary_row?(node) ? "summary" : node["node_type"].to_s
  end

  def finance_display_number?(value)
    value.to_s.strip.sub(/\.+\z/, "").match?(/\A\d+(?:\.\d+)*\z/)
  end

  def normalized_money_hash(raw)
    raw.each_with_object({}) do |(year, amount), result|
      result[year.to_i] = BigDecimal(amount.to_s)
    end
  end

  def normalized_source_money_hash(raw)
    raw.each_with_object({}) do |(key, amount), result|
      year, source_type = key.to_s.split("::", 2)
      next if year.blank? || source_type.blank?

      result[[year.to_i, funding_source_value(source_type)]] = BigDecimal(amount.to_s)
    end
  end

  def passport_row(expected_amount, actual_amount)
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
    return "TOTAL" if raw.to_s == "TOTAL"

    FundingSourceCatalog.normalize(FundingLine.source_types.fetch(raw.to_s, raw.to_s), organization: @program_version.municipal_program.organization)
  end

  def parse_document_money(raw_amount, unit)
    text = raw_amount.to_s.strip
    return nil if text.blank?

    normalized = text.gsub(/\s+/, "").tr(",", ".")
    normalized = normalized.gsub(/[^\d.-]/, "")
    return nil if normalized.blank? || normalized == "-"

    amount = BigDecimal(normalized)
    unit.to_s == "thousand_rub" ? amount * BigDecimal("1000") : amount
  rescue ArgumentError
    nil
  end

  def object_money_tolerance
    [@tolerance, BigDecimal("50")].max
  end

  def normalize_name(value)
    value.to_s.downcase.gsub(/ё/, "е").gsub(/[^[:alnum:]]+/u, " ").squish
  end

  def object_labels_by_key
    @object_labels_by_key ||= {}
  end

  def object_label_for_key(object_key)
    object_labels_by_key[object_key].presence || object_key.fetch(:normalized_name)
  end

  def aggregate_labels_by_key
    @aggregate_labels_by_key ||= {}
  end

  def aggregate_row_indexes_by_key
    @aggregate_row_indexes_by_key ||= {}
  end
end
