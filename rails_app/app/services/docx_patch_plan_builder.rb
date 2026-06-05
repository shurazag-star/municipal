require "set"

class DocxPatchPlanBuilder
  def initialize(target_program_version:, amount_items:, new_object_result:, node_map:)
    @target_program_version = target_program_version
    @amount_items = Array(amount_items)
    @new_object_result = new_object_result || {}
    @node_map = node_map || {}
  end

  def cell_updates
    changes_by_cell = {}
    nodes_by_id = @target_program_version.program_nodes.includes(:funding_lines, :parent).index_by(&:id)

    impacted_target_node_ids.each do |node_id|
      node = nodes_by_id[node_id]
      next unless node

      add_node_total_row_updates(changes_by_cell, node)
      add_funding_line_row_updates(changes_by_cell, node)
    end

    add_passport_total_updates(changes_by_cell)
    changes_by_cell.values
  end

  def text_updates
    changes_by_cell = {}
    nodes_by_id = @target_program_version.program_nodes.includes(:funding_lines, :parent).index_by(&:id)

    period_update_target_node_ids.each do |node_id|
      node = nodes_by_id[node_id]
      next unless node

      add_execution_period_update(changes_by_cell, node)
    end
    add_display_number_updates(changes_by_cell, nodes_by_id.values)

    changes_by_cell.values
  end

  private

  def impacted_target_node_ids
    ids = Set.new
    @amount_items.each do |item|
      node = @node_map[item.program_node_id]
      add_self_and_ancestors(ids, node)
    end

    target_node_ids_by_item_id.each_value do |node_id|
      node = ProgramNode.find_by(id: node_id)
      add_ancestors(ids, node)
    end
    add_related_summary_rows(ids)
    add_related_duplicate_finance_rows(ids)
    ids
  end

  def period_update_target_node_ids
    @amount_items.each_with_object(Set.new) do |item, ids|
      next unless period_changing_zeroing_item?(item)

      node = @node_map[item.program_node_id]
      ids << node.id if node
    end
  end

  def period_changing_zeroing_item?(item)
    reference = item.source_reference || {}
    reference["target_model_absent_in_excel"].present? || reference["amount_mode"].to_s == "zeroing"
  end

  def add_related_summary_rows(ids)
    return if ids.empty?

    summary_rows = @target_program_version.program_nodes.includes(:parent).select do |node|
      FinancialNodeClassifier.summary_row?(node)
    end
    summary_rows.each do |node|
      target = FinancialNodeClassifier.summary_target_node(node)
      ids << node.id if target && ids.include?(target.id)
    end
  end

  def add_related_duplicate_finance_rows(ids)
    return if ids.empty?

    nodes = @target_program_version.program_nodes.includes(:funding_lines, :children).to_a
    children_by_parent = nodes.group_by(&:parent_id)
    duplicate_finance_row_authority_map(nodes, children_by_parent).each do |mirror_id, authority_id|
      if ids.include?(authority_id) || ids.include?(mirror_id)
        ids << authority_id
        ids << mirror_id
      end
    end
  end

  def duplicate_finance_row_authority_map(nodes, children_by_parent)
    duplicate_finance_row_groups(nodes).each_with_object({}) do |(_key, group), result|
      next if group.size < 2

      authority = duplicate_finance_row_authority(group, children_by_parent)
      group.each do |node|
        result[node.id] = authority.id unless node.id == authority.id
      end
    end
  end

  def duplicate_finance_row_groups(nodes)
    nodes.select { |node| duplicate_finance_row_candidate?(node) }
      .group_by { |node| duplicate_finance_row_key(node) }
      .select { |_key, group| group.size > 1 }
  end

  def duplicate_finance_row_candidate?(node)
    node.source_table_index.present? &&
      node.source_row_index.present? &&
      node.metadata.to_h["source"].to_s.start_with?("finance")
  end

  def duplicate_finance_row_key(node)
    [
      node.parent_id,
      node.source_table_index,
      normalize_display_number(node.display_number),
      normalize_name(node.name)
    ]
  end

  def duplicate_finance_row_authority(group, children_by_parent)
    nodes_with_children = group.select do |node|
      children_by_parent.fetch(node.id, []).any? { |child| !FinancialNodeClassifier.summary_row?(child) }
    end
    candidates = nodes_with_children.presence || group
    candidates.max_by { |node| duplicate_finance_row_authority_score(node) }
  end

  def duplicate_finance_row_authority_score(node)
    [
      node.funding_lines.sum { |line| BigDecimal(line.amount_rub.to_s).abs },
      -node.source_row_index.to_i
    ]
  end

  def normalize_display_number(value)
    value.to_s.strip.sub(/\.+\z/, "")
  end

  def normalize_name(value)
    value.to_s.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def add_self_and_ancestors(ids, node)
    while node
      ids << node.id
      node = node.parent
    end
  end

  def add_ancestors(ids, node)
    current = node&.parent
    while current
      ids << current.id
      current = current.parent
    end
  end

  def target_node_ids_by_item_id
    @new_object_result["target_node_ids_by_item_id"] || {}
  end

  def add_node_total_row_updates(changes_by_cell, node)
    metadata = node.metadata || {}
    year_cell_indexes = metadata["docx_year_cell_indexes"] || {}
    return if year_cell_indexes.blank? && metadata["docx_total_cell_index"].blank?

    totals_by_year = totals_by_year_for(node.funding_lines)
    year_cell_indexes.each do |year, cell_index|
      amount = totals_by_year[year.to_i]
      next unless amount

      add_change(
        changes_by_cell,
        table_index: node.source_table_index,
        row_index: node.source_row_index,
        cell_index: cell_index,
        amount: amount,
        source_cell_raw_value: metadata.dig("docx_year_raw_values", year.to_s),
        unit: metadata["docx_unit_in_document"],
        reason: "node_total_year",
        program_node_id: node.id
      )
    end

    total_cell_index = metadata["docx_total_cell_index"]
    return if total_cell_index.blank?

    add_change(
      changes_by_cell,
      table_index: node.source_table_index,
      row_index: node.source_row_index,
      cell_index: total_cell_index,
      amount: totals_by_year.values.sum(BigDecimal("0")) { |amount| document_display_amount(amount, metadata["docx_unit_in_document"]) },
      source_cell_raw_value: metadata["docx_total_raw_value"],
      unit: metadata["docx_unit_in_document"],
      reason: "node_total_column",
      program_node_id: node.id
    )
  end

  def add_funding_line_row_updates(changes_by_cell, node)
    node.funding_lines.group_by { |line| [funding_source_value(line.source_type), line.metadata&.dig("source_row_index")] }.each_value do |lines|
      first = lines.first
      metadata = first.metadata || {}
      table_index = metadata["source_table_index"]
      row_index = metadata["source_row_index"]
      next if [table_index, row_index].any?(&:blank?)

      inferred_year_cells = inferred_year_cell_indices(lines)
      lines.each do |line|
        cell_index = line.metadata&.dig("source_cell_index") || inferred_year_cells[line.year.to_i]
        next if cell_index.blank?

        add_change(
          changes_by_cell,
          table_index: table_index,
          row_index: row_index,
          cell_index: cell_index,
          amount: BigDecimal(line.amount_rub.to_s),
          source_cell_raw_value: line.metadata&.dig("raw_value"),
          unit: line.metadata&.dig("unit_in_document"),
          change_item_id: change_item_id_for(node),
          reason: "funding_line_year",
          program_node_id: node.id
        )
      end

      total_cell_index = metadata["total_cell_index"]
      next if total_cell_index.blank?

      add_change(
        changes_by_cell,
        table_index: table_index,
        row_index: row_index,
        cell_index: total_cell_index,
        amount: lines.sum { |line| document_display_amount(line.amount_rub, metadata["unit_in_document"]) },
        source_cell_raw_value: metadata["total_raw_value"],
        unit: metadata["unit_in_document"],
        change_item_id: change_item_id_for(node),
        reason: "funding_line_total_column",
        program_node_id: node.id
      )
    end
  end

  def inferred_year_cell_indices(lines)
    explicit = lines.each_with_object({}) do |line, result|
      cell_index = line.metadata&.dig("source_cell_index")
      result[line.year.to_i] = cell_index.to_i if cell_index.present?
    end
    return explicit if explicit.empty?

    base_year, base_cell = explicit.min_by { |year, _cell| year }
    lines.each do |line|
      year = line.year.to_i
      next if explicit.key?(year)

      candidate = base_cell + (year - base_year)
      explicit[year] = candidate if candidate.positive?
    end
    explicit
  end

  def add_passport_total_updates(changes_by_cell)
    add_passport_source_updates(changes_by_cell)
    add_passport_source_total_column_updates(changes_by_cell)

    coordinates = @target_program_version.import_summary["passport_total_cell_coordinates"] || {}
    if coordinates.present?
      target_year_totals.each do |year, amount|
        coordinate = coordinates[year.to_s]
        next if coordinate.blank?

        add_change(
          changes_by_cell,
          table_index: coordinate["table_index"],
          row_index: coordinate["row_index"],
          cell_index: coordinate["cell_index"],
          amount: amount,
          source_cell_raw_value: coordinate["raw_value"],
          unit: coordinate["unit_in_document"],
          reason: "passport_total",
          program_node_id: root_total_nodes.first&.id
        )
      end
    end
    add_passport_grand_total_column_update(changes_by_cell)
  end

  def add_passport_source_updates(changes_by_cell)
    coordinates = @target_program_version.import_summary["passport_source_cell_coordinates"] || {}
    return if coordinates.blank?

    target_source_year_totals.each do |(year, source_type), amount|
      coordinate = passport_source_coordinate(coordinates, year, source_type)
      next if coordinate.blank?

      add_change(
        changes_by_cell,
        table_index: coordinate["table_index"],
        row_index: coordinate["row_index"],
        cell_index: coordinate["cell_index"],
        amount: amount,
        source_cell_raw_value: coordinate["raw_value"],
        unit: coordinate["unit_in_document"],
        reason: "passport_source_year",
        program_node_id: root_total_nodes.first&.id
      )
    end
  end

  def add_passport_source_total_column_updates(changes_by_cell)
    coordinates = @target_program_version.import_summary["passport_source_total_cell_coordinates"].presence ||
      inferred_passport_source_total_coordinates
    return if coordinates.blank?

    totals_by_source = target_source_year_totals.each_with_object({}) do |((_year, source_type), amount), totals|
      coordinate = passport_source_total_coordinate(coordinates, source_type)
      unit = coordinate&.fetch("unit_in_document", nil)
      totals[source_type] = (totals[source_type] || BigDecimal("0")) + document_display_amount(amount, unit)
    end
    totals_by_source.each do |source_type, amount|
      coordinate = passport_source_total_coordinate(coordinates, source_type)
      next if coordinate.blank?

      add_change(
        changes_by_cell,
        table_index: coordinate["table_index"],
        row_index: coordinate["row_index"],
        cell_index: coordinate["cell_index"],
        amount: amount,
        source_cell_raw_value: coordinate["raw_value"],
        unit: coordinate["unit_in_document"],
        reason: "passport_source_total_column",
        program_node_id: root_total_nodes.first&.id
      )
    end
  end

  def add_passport_grand_total_column_update(changes_by_cell)
    coordinate = @target_program_version.import_summary["passport_grand_total_cell_coordinate"].presence ||
      inferred_passport_grand_total_coordinate
    return if coordinate.blank?

    add_change(
      changes_by_cell,
      table_index: coordinate["table_index"],
      row_index: coordinate["row_index"],
      cell_index: coordinate["cell_index"],
      amount: target_year_totals.values.sum(BigDecimal("0")) { |amount| document_display_amount(amount, coordinate["unit_in_document"]) },
      source_cell_raw_value: coordinate["raw_value"],
      unit: coordinate["unit_in_document"],
      reason: "passport_grand_total_column",
      program_node_id: root_total_nodes.first&.id
    )
  end

  def add_execution_period_update(changes_by_cell, node)
    return if FinancialNodeClassifier.summary_row?(node)
    return if node.node_type == "result"
    return unless node.metadata&.dig("source").to_s.start_with?("finance")
    return unless finance_display_number?(node.display_number)
    return if [node.source_table_index, node.source_row_index].any?(&:blank?)
    return unless recalculable_execution_period?(node.execution_period)

    period = execution_period_from_lines(node.funding_lines)
    return if period.blank?

    add_text_change(
      changes_by_cell,
      table_index: node.source_table_index,
      row_index: node.source_row_index,
      cell_index: 2,
      text: period,
      reason: "execution_period",
      program_node_id: node.id
    )
  end

  def add_display_number_updates(changes_by_cell, nodes)
    nodes.each do |node|
      next unless node.metadata&.dig("docx_display_number_changed_from").present?
      next if [node.source_table_index, node.source_row_index].any?(&:blank?)

      add_text_change(
        changes_by_cell,
        table_index: node.source_table_index,
        row_index: node.source_row_index,
        cell_index: 0,
        text: display_number_for_document(node),
        reason: "display_number",
        program_node_id: node.id
      )
    end
  end

  def display_number_for_document(node)
    old_value = node.metadata&.dig("docx_display_number_changed_from").to_s
    value = node.display_number.to_s
    return "#{value}." if old_value.strip.end_with?(".") && value.present? && !value.end_with?(".")
    return "#{value}." if value.match?(/\A\d+\.\d+\z/) && normalize_name(node.name).include?("мероприятие")

    value
  end

  def add_change(changes_by_cell, table_index:, row_index:, cell_index:, amount:, source_cell_raw_value:, unit:, reason:, program_node_id:, change_item_id: nil)
    return if [table_index, row_index, cell_index].any?(&:blank?)

    key = [table_index.to_i, row_index.to_i, cell_index.to_i]
    change = {
      "change_item_id" => change_item_id,
      "table_index" => key[0],
      "row_index" => key[1],
      "cell_index" => key[2],
      "amount_rub" => BigDecimal(amount.to_s).to_s("F"),
      "source_cell_raw_value" => source_cell_raw_value,
      "unit" => unit.presence || "thousand_rub",
      "reason" => reason,
      "program_node_id" => program_node_id
    }.compact
    existing = changes_by_cell[key]
    changes_by_cell[key] = preferred_cell_change(existing, change)
  end

  def preferred_cell_change(existing, candidate)
    return candidate if existing.blank?

    existing_raw = existing["source_cell_raw_value"].present?
    candidate_raw = candidate["source_cell_raw_value"].present?
    return candidate if candidate_raw && !existing_raw
    return existing if existing_raw && !candidate_raw

    existing_amount = BigDecimal(existing["amount_rub"].to_s)
    candidate_amount = BigDecimal(candidate["amount_rub"].to_s)
    return candidate if existing_amount.zero? && !candidate_amount.zero?
    return existing if !existing_amount.zero? && candidate_amount.zero?

    candidate
  rescue ArgumentError
    candidate
  end

  def add_text_change(changes_by_cell, table_index:, row_index:, cell_index:, text:, reason:, program_node_id:)
    return if [table_index, row_index, cell_index].any?(&:blank?)

    key = [table_index.to_i, row_index.to_i, cell_index.to_i]
    changes_by_cell[key] = {
      "table_index" => key[0],
      "row_index" => key[1],
      "cell_index" => key[2],
      "text" => text.to_s,
      "reason" => reason,
      "program_node_id" => program_node_id
    }
  end

  def totals_by_year_for(lines)
    lines.each_with_object({}) do |line, totals|
      totals[line.year] = (totals[line.year] || BigDecimal("0")) + BigDecimal(line.amount_rub.to_s)
    end
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

  def passport_source_coordinate(coordinates, year, source_type)
    source_keys_for(source_type).filter_map { |key| coordinates["#{year}::#{key}"] }.first
  end

  def passport_source_total_coordinate(coordinates, source_type)
    source_keys_for(source_type).filter_map { |key| coordinates[key] }.first
  end

  def source_keys_for(source_type)
    normalized = FundingSourceCatalog.normalize(source_type, organization: @target_program_version.municipal_program.organization)
    keys = [source_type.to_s, normalized]
    FundingSourceCatalog::LEGACY_ALIASES.each do |legacy, canonical|
      keys << legacy if canonical == normalized
    end
    keys.compact.uniq
  end

  def inferred_passport_source_total_coordinates
    source_coordinates = @target_program_version.import_summary["passport_source_cell_coordinates"] || {}
    source_coordinates.each_with_object({}) do |(key, coordinate), result|
      _year, source_type = key.to_s.split("::", 2)
      next if source_type.blank? || coordinate.blank?

      cell_index = coordinate["cell_index"].to_i
      next if cell_index <= 0

      result[source_type] ||= coordinate.merge(
        "cell_index" => cell_index - 1,
        "raw_value" => nil,
        "coordinate_key" => [
          coordinate["table_index"],
          coordinate["row_index"],
          cell_index - 1
        ].join(":")
      )
    end
  end

  def inferred_passport_grand_total_coordinate
    coordinates = @target_program_version.import_summary["passport_total_cell_coordinates"] || {}
    first = coordinates.values.compact.min_by { |coordinate| coordinate["cell_index"].to_i }
    return {} if first.blank?

    cell_index = first["cell_index"].to_i
    return {} if cell_index <= 0

    first.merge(
      "cell_index" => cell_index - 1,
      "raw_value" => nil,
      "coordinate_key" => [
        first["table_index"],
        first["row_index"],
        cell_index - 1
      ].join(":")
    )
  end

  def document_display_amount(amount, unit)
    amount = BigDecimal(amount.to_s)
    return amount unless unit.to_s == "thousand_rub"

    (amount / 1000).round(2) * 1000
  end

  def execution_period_from_lines(lines)
    years = lines.select { |line| BigDecimal(line.amount_rub.to_s).nonzero? }.map(&:year).compact.uniq.sort
    return "" if years.empty?
    return years.first.to_s if years.one?

    "#{years.first}-#{years.last}"
  end

  def recalculable_execution_period?(value)
    match = value.to_s.match(/\A\s*(20\d{2})\s*[-–—]\s*(20\d{2})\s*\z/)
    return false unless match

    start_year = @target_program_version.municipal_program.period_start_year.to_i
    end_year = @target_program_version.municipal_program.period_end_year.to_i
    return true if start_year.zero? || end_year.zero?

    first = match[1].to_i
    last = match[2].to_i
    first >= start_year && last <= end_year
  end

  def finance_display_number?(value)
    value.to_s.strip.sub(/\.+\z/, "").match?(/\A\d+(?:\.\d+)*\z/)
  end

  def root_total_nodes
    @root_total_nodes ||= begin
      program_node = @target_program_version.program_nodes.includes(:funding_lines).find_by(node_type: "program")
      if program_node
        [program_node]
      else
        nodes = @target_program_version.program_nodes.includes(:funding_lines).to_a
        by_id = nodes.index_by(&:id)
        nodes.select { |node| node.parent_id.blank? || !by_id.key?(node.parent_id) }
      end
    end
  end

  def change_item_id_for(target_node)
    source_node_id = target_node.metadata&.dig("source_program_node_id")
    @amount_items.find { |item| item.program_node_id == source_node_id }&.id
  end

  def funding_source_value(raw)
    FundingLine.source_types.fetch(raw.to_s, raw.to_s)
  end
end
