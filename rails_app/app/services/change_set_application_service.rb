require "set"
require "stringio"

class ChangeSetApplicationService
  class Error < StandardError; end
  class NotApproved < Error; end
  class ConfirmationRequired < Error; end
  class SourceDocxMissing < Error; end

  Result = Struct.new(:change_set, :target_program_version, :docx_patch, :manual_insert_required_count, keyword_init: true)
  SourceDocx = Struct.new(:bytes, :label, :row_insertions, keyword_init: true)

  DOCX_CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document".freeze

  def initialize(change_set:, user:, patch_client: DocxPatchClient.new, post_export_validator: nil)
    @change_set = change_set
    @user = user
    @patch_client = patch_client
    @post_export_validator = post_export_validator
    @node_map = {}
  end

  def apply!
    @change_set.reload
    return already_applied_result if @change_set.applied?

    validate_change_set!
    source_docx = source_docx_source!

    ActiveRecord::Base.transaction do
      target_version = clone_program_version!
      applied_items = apply_amount_items!(target_version)
      new_object_result = apply_new_object_items!(target_version)
      recalculate_target_model!(target_version, applied_items, new_object_result)
      insert_objects = docx_insert_objects(target_version, new_object_result)
      patch_result = attach_generated_docx!(source_docx, target_version, applied_items, new_object_result, insert_objects)
      manual_insert_count = manual_insert_required_count(new_object_result, patch_result)
      post_export_validation = validate_generated_docx(target_version, patch_result.bytes)
      external_patch_ledger = build_external_patch_ledger(target_version, new_object_result)
      external_patch_validation = validate_external_patch_ledger(target_version, external_patch_ledger, post_export_validation)
      export_summary = export_summary_for(target_version, patch_result, manual_insert_count, new_object_result, post_export_validation, external_patch_ledger, external_patch_validation)
      attach_report!(target_version, export_summary)
      agent_self_check = AgentSelfCheckService.new(
        change_set: @change_set,
        export_summary: export_summary,
        persist: false,
        reload_record: false
      ).call
      export_summary = export_summary.merge("agent_self_check" => agent_self_check)
      independent_verifier = IndependentVerifierAgent.new(
        change_set: @change_set,
        target_program_version: target_version,
        export_summary: export_summary
      ).verify
      export_summary = export_summary.merge("independent_verifier" => independent_verifier)
      final_status = final_status_for(post_export_validation, manual_insert_count, agent_self_check, independent_verifier)

      @change_set.update!(
        status: final_status,
        target_program_version: target_version,
        applied_at: final_status == "applied" ? Time.current : nil,
        export_summary: export_summary,
        summary: applied_summary(applied_items.count, manual_insert_count, patch_result.payload, final_status)
      )
      target_version.update!(status: target_version_status_for(final_status))
      Result.new(
        change_set: @change_set,
        target_program_version: target_version,
        docx_patch: patch_result.payload,
        manual_insert_required_count: manual_insert_count
      )
    end
  end

  private

  def already_applied_result
    Result.new(
      change_set: @change_set,
      target_program_version: @change_set.target_program_version,
      docx_patch: @change_set.export_summary["docx_patch"] || {},
      manual_insert_required_count: @change_set.export_summary["manual_insert_required_count"].to_i
    )
  end

  def validate_change_set!
    raise ConfirmationRequired, "В проекте изменений нет строк для применения" if @change_set.change_items.where.not(status: "rejected").empty?

    AgentAutonomousResolver.new(change_set: @change_set, user: @user).resolve!
    unresolved = @change_set.change_items.where(agent_resolution_status: %w[unresolved needs_clarification]).where.not(status: "rejected")
    if unresolved.exists?
      raise ConfirmationRequired, "Есть строки, которые агент не смог надежно разобрать по документам"
    end
    self_check = AgentSelfCheckService.new(change_set: @change_set, persist: false, reload_record: false).call
    pre_export_blockers = Array(self_check["blocking_reasons"]).select { |reason| pre_export_blocking_reason?(reason) }
    if self_check["status"] != "passed" && pre_export_blockers.any?
      raise ConfirmationRequired, pre_export_blockers.first
    end
  end

  def pre_export_blocking_reason?(reason)
    text = reason.to_s
    return false if text.include?("PDF-операции не подтверждены после экспорта")
    return false if text.include?("PDF-журнал частичных правок не готов")

    text.match?(/конфликт|уточн|неразобран|не подтвержд|покрыва|Excel-цель|PDF-журнал/)
  end

  def source_docx_source!
    generated_source = generated_source_change_set
    if generated_source&.generated_docx_attachment&.attached?
      bytes = generated_source.generated_docx_attachment.download
      if docx_package_bytes?(bytes)
        return SourceDocx.new(
          bytes: bytes,
          label: "changeset_#{generated_source.id}",
          row_insertions: generated_docx_row_insertions_for(generated_source)
        )
      end
    end

    source_document_id = @change_set.program_version.import_summary["source_document_id"]
    document = SourceDocument.find_by(id: source_document_id) if source_document_id.present?
    document ||= @change_set.program_version.municipal_program.organization.source_documents.docx_program.order(updated_at: :desc).first
    raise SourceDocxMissing, "Исходный DOCX не найден" unless document&.file_attachment&.attached?

    SourceDocx.new(bytes: document.file_attachment.download, label: "source_document_#{document.id}", row_insertions: [])
  end

  def docx_package_bytes?(bytes)
    bytes.to_s.byteslice(0, 2) == "PK"
  end

  def generated_source_change_set
    version = @change_set.program_version
    source_change_set_id = version.import_summary["source_change_set_id"]
    source_change_set = ChangeSet.find_by(id: source_change_set_id) if source_change_set_id.present?
    return source_change_set if reusable_generated_docx_source?(source_change_set, version)

    ChangeSet
      .where(target_program_version: version)
      .order(updated_at: :desc)
      .detect { |change_set| reusable_generated_docx_source?(change_set, version) }
  end

  def reusable_generated_docx_source?(change_set, version)
    change_set&.target_program_version_id == version.id &&
      change_set.export_ready? &&
      change_set.generated_docx_attachment.attached?
  end

  def generated_docx_row_insertions_for(change_set)
    stored = change_set&.export_summary&.fetch("docx_row_insertions", nil)
    return normalize_docx_row_insertions(stored) if stored.present?

    normalize_docx_row_insertions(change_set&.export_summary&.dig("docx_patch", "inserted"))
  end

  def normalize_docx_row_insertions(insertions)
    Array(insertions).filter_map do |entry|
      table_index = entry["table_index"]
      insert_after_row_index = entry["insert_after_row_index"]
      rows_count = entry["rows_count"].presence || entry["inserted_rows_count"].presence || Array(entry["rows"]).size
      next if [table_index, insert_after_row_index].any?(&:blank?)
      next if rows_count.to_i <= 0

      {
        "table_index" => table_index.to_i,
        "insert_after_row_index" => insert_after_row_index.to_i,
        "rows_count" => rows_count.to_i
      }
    end
  end

  def clone_program_version!
    source_version = @change_set.program_version
    program = source_version.municipal_program
    target_version = program.program_versions.create!(
      created_by: @user,
      version_number: (program.program_versions.maximum(:version_number) || source_version.version_number) + 1,
      status: "generated_draft",
      import_summary: source_version.import_summary.merge(
        "source_program_version_id" => source_version.id,
        "source_change_set_id" => @change_set.id
      )
    )

    source_nodes = source_version.program_nodes.includes(:funding_lines).order(:id)
    source_nodes.each do |node|
      @node_map[node.id] = target_version.program_nodes.create!(
        node_type: node.node_type,
        code: node.code,
        external_code: node.external_code,
        display_number: node.display_number,
        name: node.name,
        normalized_name: node.normalized_name,
        responsible: node.responsible,
        execution_period: node.execution_period,
        source_table_index: node.source_table_index,
        source_row_index: node.source_row_index,
        metadata: (node.metadata || {}).merge("source_program_node_id" => node.id)
      )
    end

    source_nodes.each do |node|
      target_node = @node_map[node.id]
      target_node.update!(parent: @node_map[node.parent_id]) if node.parent_id.present? && @node_map[node.parent_id]
      node.funding_lines.each do |line|
        copy_funding_line!(target_node, line)
      end
    end

    target_version
  end

  def copy_funding_line!(target_node, line)
    target_node.funding_lines.create!(
      year: line.year,
      source_type: funding_source_key(line.source_type),
      amount_rub: line.amount_rub,
      amount_kind: line.amount_kind,
      source_document: line.source_document,
      source_row_ref: line.source_row_ref,
      raw_source_name: line.raw_source_name,
      metadata: (line.metadata || {}).merge("source_funding_line_id" => line.id)
    )
  end

  def apply_amount_items!(target_version)
    amount_items.map do |item|
      target_node = @node_map[item.program_node_id]
      next unless target_node

      line = find_target_line(target_node, item.year, item.source_type)
      line ||= build_target_line(target_node, item)
      line.update!(amount_rub: item.new_amount_rub)
      item
    end.compact
  end

  def apply_new_object_items!(target_version)
    result = {
      "created_groups" => [],
      "manual_item_ids" => [],
      "target_node_ids_by_item_id" => {}
    }

    new_object_items.group_by { |item| source_group_key(item) }.each do |group_key, items|
      parent = resolve_parent_node(target_version, items.first)
      unless parent
        result["manual_item_ids"].concat(items.map(&:id))
        next
      end

      node = create_new_object_node!(target_version, parent, group_key, items)
      create_new_object_funding_lines!(node, items)
      items.each { |item| result["target_node_ids_by_item_id"][item.id.to_s] = node.id }
      result["created_groups"] << {
        "group_key" => group_key,
        "target_node_id" => node.id,
        "item_ids" => items.map(&:id)
      }
    end

    result
  end

  def create_new_object_node!(target_version, parent, group_key, items)
    reference = items.first.source_reference || {}
    virtual_residual = virtual_residual_group?(items)
    name = new_object_name(items)
    display_number = next_child_display_number(parent)
    target_version.program_nodes.create!(
      parent: parent,
      node_type: residual_group?(items) ? "residual" : "object",
      code: reference["object_code"].presence,
      external_code: reference["object_code"].presence,
      display_number: display_number,
      name: name,
      normalized_name: normalize_name(name),
      execution_period: execution_period_for_items(items),
      source_table_index: parent.source_table_index,
      source_row_index: nil,
      metadata: {
        "source_change_set_id" => @change_set.id,
        "source_change_item_ids" => items.map(&:id),
        "source_group_key" => group_key,
        "parent_activity_code" => reference["parent_activity_code"],
        "object_code" => reference["object_code"],
        "docx_insert_status" => virtual_residual ? "virtual" : "pending",
        "docx_virtual_residual" => (true if virtual_residual)
      }.compact
    )
  end

  def create_new_object_funding_lines!(node, items)
    items.group_by { |item| [item.year, funding_source_value(item.source_type)] }.each do |(year, source_type), grouped_items|
      amount = grouped_items.sum { |item| BigDecimal(item.new_amount_rub.to_s) }
      reference = grouped_items.first.source_reference || {}
      source_document = SourceDocument.find_by(id: reference["source_document_id"])
      node.funding_lines.create!(
        year: year,
        source_type: funding_source_key(source_type),
        amount_rub: amount,
        amount_kind: "planned",
        source_document: source_document,
        source_row_ref: reference["row_number"].presence&.to_s,
        raw_source_name: source_type,
        metadata: {
          "source_change_item_ids" => grouped_items.map(&:id),
          "source_group_key" => reference["group_key"],
          "source_row_number" => reference["row_number"],
          "source_table_index" => node.source_table_index,
          "unit_in_document" => "thousand_rub",
          "docx_inserted" => true
        }.compact
      )
    end
  end

  def find_target_line(target_node, year, source_type)
    source_value = funding_source_value(source_type)
    target_node.funding_lines.reload.detect do |line|
      line.year == year && funding_source_value(line.source_type) == source_value
    end
  end

  def build_target_line(target_node, item)
    source_line = item.program_node.funding_lines.detect do |line|
      line.year == item.year && funding_source_value(line.source_type) == funding_source_value(item.source_type)
    end
    target_node.funding_lines.build(
      year: item.year,
      source_type: funding_source_key(item.source_type),
      amount_kind: "planned",
      source_document: source_line&.source_document,
      source_row_ref: source_line&.source_row_ref,
      raw_source_name: item.source_type,
      metadata: source_line&.metadata || {}
    )
  end

  def recalculate_target_model!(target_version, applied_items, new_object_result)
    if partial_source_mode?
      recalculate_partial_tree!(target_version, applied_items, new_object_result)
    else
      recalculate_tree!(target_version)
    end
    reconcile_to_external_target!(target_version) if xlsx_target_source_mode?
  end

  def recalculate_partial_tree!(target_version, applied_items, new_object_result)
    deltas_by_node_id = Hash.new { |hash, key| hash[key] = Hash.new(BigDecimal("0")) }

    applied_items.each do |item|
      target_node = @node_map[item.program_node_id]
      next unless target_node

      add_partial_delta_to_ancestors!(deltas_by_node_id, target_node.parent, partial_amount_delta_for(item))
    end

    Array((new_object_result["target_node_ids_by_item_id"] || {}).values).uniq.each do |node_id|
      node = target_version.program_nodes.includes(:funding_lines, :parent).find_by(id: node_id)
      next unless node

      add_partial_delta_to_ancestors!(deltas_by_node_id, node.parent, aggregate_lines(node.funding_lines))
    end

    apply_partial_deltas!(target_version, deltas_by_node_id)
    reconcile_program_root_to_passport_baseline!(target_version, deltas_by_node_id)
    update_partial_summary_rows!(target_version, deltas_by_node_id)
  end

  def partial_amount_delta_for(item)
    year = item.year.to_i
    source_type = funding_source_value(item.source_type)
    return {} if year.zero? || source_type.blank?

    delta =
      if item.delta_rub.present?
        BigDecimal(item.delta_rub.to_s)
      else
        BigDecimal(item.new_amount_rub.to_s) - BigDecimal((item.old_amount_rub || 0).to_s)
      end
    { [year, source_type] => delta }
  end

  def add_partial_delta_to_ancestors!(deltas_by_node_id, node, deltas)
    current = node
    while current
      unless FinancialNodeClassifier.summary_row?(current)
        deltas.each do |key, delta|
          deltas_by_node_id[current.id][key] += BigDecimal(delta.to_s)
        end
      end
      current = current.parent
    end
  end

  def apply_partial_deltas!(target_version, deltas_by_node_id)
    return if deltas_by_node_id.blank?

    nodes_by_id = target_version.program_nodes.includes(:funding_lines).where(id: deltas_by_node_id.keys).index_by(&:id)
    deltas_by_node_id.each do |node_id, deltas|
      update_node_funding_by_deltas!(nodes_by_id[node_id], deltas)
    end
  end

  def update_partial_summary_rows!(target_version, deltas_by_node_id)
    return if deltas_by_node_id.blank?

    target_version.program_nodes.includes(:funding_lines, :parent).select { |node| FinancialNodeClassifier.summary_row?(node) }.each do |summary_node|
      target = FinancialNodeClassifier.summary_target_node(summary_node)
      deltas = deltas_by_node_id[target&.id]
      next if deltas.blank?

      update_node_funding_by_deltas!(summary_node, deltas)
    end
  end

  def update_node_funding_by_deltas!(node, deltas)
    return unless node

    existing_by_key = node.funding_lines.reload.group_by { |line| [line.year.to_i, funding_source_value(line.source_type)] }
    deltas.each do |(year, source_type), delta|
      delta = BigDecimal(delta.to_s)
      next if delta.zero?

      existing = existing_by_key[[year.to_i, source_type]]
      if existing.present?
        line = existing.first
        line.update!(amount_rub: BigDecimal(line.amount_rub.to_s) + delta)
      else
        reference = reference_funding_line_for(node, source_type)
        node.funding_lines.create!(
          year: year,
          source_type: funding_source_key(source_type),
          amount_rub: delta,
          amount_kind: reference&.amount_kind || "planned",
          source_document: reference&.source_document,
          source_row_ref: reference&.source_row_ref,
          raw_source_name: reference&.raw_source_name || source_type,
          metadata: reference&.metadata || {}
        )
      end
    end
  end

  def reconcile_program_root_to_passport_baseline!(target_version, deltas_by_node_id)
    root = target_version.program_nodes.find_by(node_type: "program")
    return unless root
    return if source_program_root_has_funding_lines?(root)

    baseline = passport_baseline_source_year_totals(target_version)
    return if baseline.blank?

    totals = baseline.dup
    deltas_by_node_id[root.id].to_h.each do |key, delta|
      year, source_type = key
      normalized_key = [year.to_i, funding_source_value(source_type)]
      totals[normalized_key] = (totals[normalized_key] || BigDecimal("0")) + BigDecimal(delta.to_s)
    end
    replace_node_funding_with_totals!(root, totals)
  end

  def source_program_root_has_funding_lines?(target_root)
    source_root_id = target_root.metadata&.dig("source_program_node_id")
    source_root = ProgramNode.find_by(id: source_root_id) if source_root_id.present?
    source_root&.funding_lines&.exists?
  end

  def passport_baseline_source_year_totals(target_version)
    source_document_id = target_version.import_summary["source_document_id"]
    payload = SourceDocument.find_by(id: source_document_id)&.parsed_payload || {}
    amounts = payload["passport_amounts"] || {}
    amounts.each_with_object({}) do |(key, amount), totals|
      year, source_type = key.to_s.split("::", 2)
      next if year.blank? || source_type.blank?

      totals[[year.to_i, funding_source_value(source_type)]] = BigDecimal(amount.to_s)
    rescue ArgumentError
      next
    end
  end

  def reference_funding_line_for(node, source_type)
    node.funding_lines.detect { |line| funding_source_value(line.source_type) == source_type } || node.funding_lines.first
  end

  def recalculate_tree!(target_version)
    nodes = target_version.program_nodes.includes(:funding_lines, :children).to_a
    by_id = nodes.index_by(&:id)
    children_by_parent = nodes.group_by(&:parent_id)
    roots = nodes.select { |node| node.parent_id.blank? || !by_id.key?(node.parent_id) }
    totals_by_node_id = {}

    visit = lambda do |node|
      return {} if FinancialNodeClassifier.summary_row?(node)

      regular_children = children_by_parent.fetch(node.id, []).reject { |child| FinancialNodeClassifier.summary_row?(child) }
      child_totals = regular_children.map { |child| visit.call(child) }
      if child_totals.empty?
        totals = aggregate_lines(node.funding_lines)
        totals_by_node_id[node.id] = totals
        return totals
      end

      totals = merge_totals(child_totals)
      replace_node_funding_with_totals!(node, totals)
      totals_by_node_id[node.id] = totals
      totals
    end

    roots.each { |node| visit.call(node) }
    update_summary_rows!(nodes, totals_by_node_id)
  end

  def update_summary_rows!(nodes, totals_by_node_id)
    nodes.select { |node| FinancialNodeClassifier.summary_row?(node) }.each do |node|
      target = FinancialNodeClassifier.summary_target_node(node)
      totals = totals_by_node_id[target&.id]
      next if totals.blank?

      replace_node_funding_with_totals!(node, totals)
    end
  end

  def reconcile_to_external_target!(target_version)
    expected = external_target_source_totals
    return if expected.blank?

    actual = root_source_totals(target_version)
    tolerance = BigDecimal(AgentSetting.for_organization!(@change_set.program_version.municipal_program.organization).money_tolerance_rub.to_s)
    deltas = expected.each_with_object({}) do |(key, expected_amount), result|
      delta = BigDecimal(expected_amount.to_s) - BigDecimal(actual.fetch(key, 0).to_s)
      result[key] = delta if delta.abs > tolerance
    end
    return if deltas.blank?

    root = target_version.program_nodes.find_by(node_type: "program") || root_nodes(target_version).first
    return unless root

    adjustment = target_version.program_nodes.create!(
      parent: root,
      node_type: "residual",
      name: "Корректировка до целевой модели Excel",
      normalized_name: normalize_name("Корректировка до целевой модели Excel"),
      display_number: next_child_display_number(root),
      execution_period: execution_period_for_years(deltas.keys.map(&:first)),
      metadata: {
        "source_change_set_id" => @change_set.id,
        "excel_target_reconciliation" => true,
        "reason" => "Закрытие остаточной разницы между автоматическим сопоставлением строк и контрольными суммами Excel"
      }
    )
    deltas.each do |(year, source_type), amount|
      adjustment.funding_lines.create!(
        year: year,
        source_type: funding_source_key(source_type),
        amount_rub: amount,
        amount_kind: "planned",
        source_document: external_financial_target_document,
        raw_source_name: source_type,
        metadata: {
          "excel_target_reconciliation" => true,
          "source_mode" => "xlsx_target"
        }
      )
    end
    @external_target_reconciliation = {
      "status" => "applied",
      "target_node_id" => adjustment.id,
      "deltas" => deltas.map do |(year, source_type), amount|
        {
          "year" => year,
          "source_type" => source_type,
          "amount_rub" => amount.to_s("F")
        }
      end
    }
    recalculate_tree!(target_version)
  end

  def external_target_source_totals
    document = external_financial_target_document
    return {} unless document&.xlsx_finance?

    program_total_row = Array(document.parsed_payload["rows"]).detect do |row|
      row["row_type"].to_s == "PROGRAM_TOTAL_ROW" && row["funding"].present?
    end
    funding = program_total_row&.fetch("funding", nil) || {}
    funding.each_with_object({}) do |(key, amount), result|
      year, source_type = key.to_s.split("::", 2)
      next if year.blank? || source_type.blank?

      result[[year.to_i, funding_source_value(source_type)]] = BigDecimal(amount.to_s)
    end
  rescue ArgumentError
    {}
  end

  def root_source_totals(target_version)
    root_nodes(target_version).flat_map(&:funding_lines).each_with_object({}) do |line, totals|
      key = [line.year, funding_source_value(line.source_type)]
      totals[key] = (totals[key] || BigDecimal("0")) + BigDecimal(line.amount_rub.to_s)
    end
  end

  def root_nodes(target_version)
    program_node = target_version.program_nodes.includes(:funding_lines).find_by(node_type: "program")
    return [program_node] if program_node

    nodes = target_version.program_nodes.includes(:funding_lines).to_a
    by_id = nodes.index_by(&:id)
    nodes.select { |node| node.parent_id.blank? || !by_id.key?(node.parent_id) }
  end

  def aggregate_lines(lines)
    lines.each_with_object({}) do |line, totals|
      key = [line.year, funding_source_value(line.source_type)]
      totals[key] = (totals[key] || BigDecimal("0")) + BigDecimal(line.amount_rub.to_s)
    end
  end

  def merge_totals(total_hashes)
    total_hashes.each_with_object({}) do |hash, result|
      hash.each do |key, amount|
        result[key] = (result[key] || BigDecimal("0")) + amount
      end
    end
  end

  def replace_node_funding_with_totals!(node, totals)
    existing_by_key = node.funding_lines.index_by { |line| [line.year, funding_source_value(line.source_type)] }
    node.funding_lines.destroy_all
    totals.each do |(year, source_type), amount|
      previous = existing_by_key[[year, source_type]]
      node.funding_lines.create!(
        year: year,
        source_type: funding_source_key(source_type),
        amount_rub: amount,
        amount_kind: previous&.amount_kind || "planned",
        source_document: previous&.source_document,
        source_row_ref: previous&.source_row_ref,
        raw_source_name: previous&.raw_source_name || source_type,
        metadata: previous&.metadata || {}
      )
    end
  end

  def attach_generated_docx!(source_docx, target_version, applied_items, new_object_result, insert_objects)
    patch_plan = docx_patch_plan(target_version, applied_items, new_object_result)
    changes = patch_plan.merge(
      "insert_objects" => insert_objects
    )
    @generated_docx_row_insertions = merge_docx_row_insertions(source_docx.row_insertions, insert_objects)
    changes = adjust_patch_coordinates_for_source_docx(changes, source_docx)
    patch_result = @patch_client.patch(
      source_docx_bytes: source_docx.bytes,
      source_label: source_docx.label,
      changes: changes
    )
    io = StringIO.new(patch_result.bytes)
    io.set_encoding(Encoding::BINARY)
    @change_set.generated_docx_attachment.attach(
      io: io,
      filename: "changeset-#{@change_set.id}-version-#{target_version.version_number}.docx",
      content_type: DOCX_CONTENT_TYPE
    )
    patch_result
  end

  def merge_docx_row_insertions(existing_insertions, new_insertions)
    normalize_docx_row_insertions(existing_insertions) + normalize_docx_row_insertions(new_insertions)
  end

  def adjust_patch_coordinates_for_source_docx(changes, source_docx)
    row_insertions = normalize_docx_row_insertions(source_docx.row_insertions)
    return changes if row_insertions.blank?

    Array(changes["cell_updates"]).each do |update|
      update["row_index"] = translated_docx_row_index(
        update["table_index"],
        update["row_index"],
        row_insertions,
        include_same_anchor: false
      )
    end
    Array(changes["text_updates"]).each do |update|
      update["row_index"] = translated_docx_row_index(
        update["table_index"],
        update["row_index"],
        row_insertions,
        include_same_anchor: false
      )
    end
    Array(changes["insert_objects"]).each do |insert_object|
      insert_object["insert_after_row_index"] = translated_docx_row_index(
        insert_object["table_index"],
        insert_object["insert_after_row_index"],
        row_insertions,
        include_same_anchor: true
      )
      insert_object["template_row_index"] = translated_docx_row_index(
        insert_object["table_index"],
        insert_object["template_row_index"],
        row_insertions,
        include_same_anchor: false
      )
    end
    changes
  end

  def translated_docx_row_index(table_index, row_index, row_insertions, include_same_anchor:)
    return row_index if [table_index, row_index].any?(&:blank?)

    table_index = table_index.to_i
    row_index = row_index.to_i
    offset = row_insertions.sum do |insertion|
      next 0 unless insertion["table_index"].to_i == table_index

      anchor = insertion["insert_after_row_index"].to_i
      shifted = include_same_anchor ? anchor <= row_index : anchor < row_index
      shifted ? insertion["rows_count"].to_i : 0
    end
    row_index + offset
  end

  def docx_patch_plan(target_version, applied_items, new_object_result)
    builder = DocxPatchPlanBuilder.new(
      target_program_version: target_version,
      amount_items: applied_items,
      new_object_result: new_object_result,
      node_map: @node_map
    )
    {
      "cell_updates" => builder.cell_updates,
      "text_updates" => builder.text_updates
    }
  end

  def docx_insert_objects(target_version, new_object_result)
    row_offsets_by_anchor = Hash.new(0)
    Array(new_object_result["created_groups"]).filter_map do |group|
      node = target_version.program_nodes.includes(:funding_lines, :parent).find_by(id: group["target_node_id"])
      next unless node&.parent
      next if node.metadata&.dig("docx_virtual_residual")

      anchor = docx_insert_anchor(node.parent, node)
      next unless anchor

      rows = docx_insert_rows(node)
      next if rows.empty?

      anchor_key = [anchor["table_index"], anchor["insert_after_row_index"]]
      assigned_row_index = anchor["insert_after_row_index"].to_i + 1 + row_offsets_by_anchor[anchor_key]
      row_offsets_by_anchor[anchor_key] += rows.size
      node.update!(
        source_table_index: anchor["table_index"],
        source_row_index: assigned_row_index,
        metadata: (node.metadata || {}).merge(
          "docx_insert_status" => "queued",
          "docx_insert_after_row_index" => anchor["insert_after_row_index"],
          "docx_insert_rows_count" => rows.size
        )
      )

      {
        "change_item_ids" => group["item_ids"],
        "target_node_id" => node.id,
        "table_index" => anchor["table_index"],
        "insert_after_row_index" => anchor["insert_after_row_index"],
        "template_row_index" => anchor["template_row_index"],
        "parent_display_number" => node.parent.display_number,
        "display_number" => node.display_number,
        "object_name" => node.name,
        "execution_period" => node.execution_period.presence || execution_period_from_lines(node.funding_lines),
        "active_years" => active_years_for_lines(node.funding_lines),
        "total_cell_index" => 4,
        "year_cell_indices" => year_cell_indices_for(target_version, anchor["table_index"]),
        "rows" => rows
      }
    end
  end

  def docx_insert_anchor(parent, node)
    table_index = parent.source_table_index
    return nil if table_index.blank?

    siblings = parent.children
      .where.not(id: node.id)
      .where(source_table_index: table_index)
      .where.not(source_row_index: nil)
      .order(source_row_index: :asc)
      .to_a
      .reject { |child| child.metadata&.dig("source_change_set_id").present? }
      .select { |child| finance_display_number?(child.display_number) }
    last_sibling = siblings.last
    insert_after_row_index = occupied_last_row_index(last_sibling) || occupied_last_row_index(parent) || parent.source_row_index
    return nil if insert_after_row_index.blank?

    {
      "table_index" => table_index,
      "insert_after_row_index" => insert_after_row_index,
      "template_row_index" => last_sibling&.source_row_index || insert_after_row_index
    }
  end

  def occupied_last_row_index(node)
    return nil unless node

    indexes = [node.source_row_index]
    node.funding_lines.each do |line|
      next unless line.metadata&.dig("source_table_index").to_i == node.source_table_index.to_i

      indexes << line.metadata&.dig("source_row_index")
    end
    indexes.compact.map(&:to_i).max
  end

  def finance_display_number?(value)
    value.to_s.strip.sub(/\.+\z/, "").match?(/\A\d+(?:\.\d+)*\z/)
  end

  def year_cell_indices_for(target_version, table_index)
    lines = target_version.program_nodes
      .where(source_table_index: table_index)
      .includes(:funding_lines)
      .flat_map(&:funding_lines)
    mapped = lines.each_with_object({}) do |line, result|
      cell_index = line.metadata&.dig("source_cell_index")
      next if cell_index.blank?

      result[line.year.to_s] ||= cell_index.to_i
    end
    return mapped if mapped.any?

    years = target_version.municipal_program.period_start_year..target_version.municipal_program.period_end_year
    years.each_with_index.to_h { |year, offset| [year.to_s, 4 + offset] }
  end

  def docx_insert_rows(node)
    lines = node.funding_lines.to_a
    return [] if lines.empty?

    years = lines.map(&:year).compact.sort
    total_by_year = years.index_with do |year|
      lines.select { |line| line.year == year }.sum(BigDecimal("0")) { |line| BigDecimal(line.amount_rub.to_s) }
    end
    rows = [
      {
        "source_type" => "TOTAL",
        "source_label" => "Итого",
        "total_amount_rub" => total_by_year.values.sum(BigDecimal("0")).to_s("F"),
        "amounts_by_year" => total_by_year.transform_values { |amount| amount.to_s("F") },
        "unit" => "thousand_rub"
      }
    ]

    source_lines_by_type = lines.group_by { |line| funding_source_value(line.source_type) }
    docx_insert_source_types(node, lines).each do |source_type|
      source_lines = source_lines_by_type.fetch(source_type, [])
      amounts_by_year = years.index_with do |year|
        source_lines.select { |line| line.year == year }.sum(BigDecimal("0")) { |line| BigDecimal(line.amount_rub.to_s) }
      end
      rows << {
        "source_type" => source_type,
        "source_label" => source_label_for(node, source_type),
        "total_amount_rub" => amounts_by_year.values.sum(BigDecimal("0")).to_s("F"),
        "amounts_by_year" => amounts_by_year.transform_values { |amount| amount.to_s("F") },
        "unit" => "thousand_rub"
      }
    end

    rows
  end

  def docx_insert_source_types(node, lines)
    node_source_types = lines.map { |line| funding_source_value(line.source_type) }.uniq
    context_source_types = Array(node.parent&.funding_lines).map { |line| funding_source_value(line.source_type) }.uniq
    source_types = (context_source_types + node_source_types).uniq
    source_types = node_source_types if source_types.empty?
    source_types.sort_by { |source_type| source_sort_order(source_type) }
  end

  def attach_report!(target_version, export_summary)
    html = ChangeSetReportBuilder.new(
      change_set: @change_set,
      target_program_version: target_version,
      export_summary: export_summary
    ).html
    @change_set.change_report_attachment.attach(
      io: StringIO.new(html),
      filename: "changeset-#{@change_set.id}-report.html",
      content_type: "text/html"
    )
  end

  def validate_generated_docx(target_version, generated_docx_bytes)
    validator = @post_export_validator || configured_post_export_validator
    if validator
      return validator.validate(
        program_version: target_version,
        generated_docx_attachment: @change_set.generated_docx_attachment,
        generated_docx_bytes: generated_docx_bytes
      )
    end

    PostExportDocxValidator.new(
      program_version: target_version,
      generated_docx_attachment: @change_set.generated_docx_attachment,
      generated_docx_bytes: generated_docx_bytes,
      external_target_document: external_financial_target_document
    ).validate
  end

  def external_financial_target_document
    session = @change_set.analysis_session
    ids = Array(session&.selected_source_document_ids)
    scope = @change_set.program_version.municipal_program.organization.source_documents.xlsx_finance
    scope = scope.where(id: ids) if ids.any?
    scope.order(updated_at: :desc).first
  end

  def configured_post_export_validator
    validator = Rails.application.config.x.post_export_validator
    return nil if validator.is_a?(ActiveSupport::OrderedOptions)

    validator
  end

  def final_status_for(post_export_validation, manual_insert_count, agent_self_check = nil, independent_verifier = nil)
    return "export_failed" if post_export_validation["status"] == "invalid"
    return "needs_manual_review" if manual_insert_count.to_i.positive?
    return "needs_manual_review" if agent_self_check && agent_self_check["status"] != "passed"
    return "needs_manual_review" if independent_verifier && independent_verifier["status"] != "passed"

    "applied"
  end

  def target_version_status_for(final_status)
    case final_status
    when "applied" then "generated_validated"
    when "export_failed" then "generated_rejected"
    else "generated_draft"
    end
  end

  def export_summary_for(target_version, patch_result, manual_insert_count, new_object_result, post_export_validation, external_patch_ledger = nil, external_patch_validation = nil)
    {
      "target_program_version_id" => target_version.id,
      "applied_change_items_count" => amount_items.count,
      "manual_insert_required_count" => manual_insert_count,
      "new_objects" => {
        "created_groups_count" => Array(new_object_result["created_groups"]).size,
        "manual_item_ids" => Array(new_object_result["manual_item_ids"]),
        "target_node_ids_by_item_id" => new_object_result["target_node_ids_by_item_id"] || {}
      },
      "docx_row_insertions" => @generated_docx_row_insertions,
      "docx_patch" => patch_result.payload,
      "post_export_validation" => post_export_validation,
      "external_patch_ledger" => external_patch_ledger,
      "external_patch_validation" => external_patch_validation,
      "external_target_reconciliation" => @external_target_reconciliation,
      "source_conflicts" => Array(@change_set.analysis_session&.summary&.fetch("source_conflicts", nil)),
      "report_filename" => "changeset-#{@change_set.id}-report.html"
    }.compact
  end

  def build_external_patch_ledger(target_version, new_object_result)
    return nil unless pdf_patch_mode?

    ExternalPatchLedgerBuilder.new(
      change_set: @change_set,
      target_program_version: target_version,
      new_object_result: new_object_result
    ).build
  end

  def validate_external_patch_ledger(target_version, ledger, post_export_validation)
    return nil if ledger.blank?

    ExternalPatchLedgerValidator.new(
      change_set: @change_set,
      target_program_version: target_version,
      ledger: ledger,
      post_export_validation: post_export_validation
    ).validate
  end

  def pdf_patch_mode?
    effective_source_mode == "pdf_patch"
  end

  def partial_source_mode?
    effective_source_mode.in?(%w[pdf_patch manual_instruction])
  end

  def xlsx_target_source_mode?
    SourceModeResolver.xlsx_target_mode?(effective_source_mode)
  end

  def effective_source_mode
    @effective_source_mode ||= begin
      mode = @change_set.analysis_session&.effective_source_mode
      inferred = inferred_source_mode_from_change_items
      normalized_mode = SourceModeResolver.normalize(mode)
      inferred || (normalized_mode unless normalized_mode == "auto")
    end
  end

  def inferred_source_mode_from_change_items
    references = @change_set.change_items.map { |item| item.source_reference || {} }
    source_modes = references.filter_map { |reference| SourceModeResolver.normalize(reference["source_mode"]) }
    document_types = references.map { |reference| reference["document_type"].to_s }
    return "manual_instruction" if source_modes.include?("manual_instruction") || document_types.include?("manual_instruction")
    return "pdf_patch" if source_modes.include?("pdf_patch") || document_types.include?("pdf_agreement")
    return "xlsx_target" if source_modes.any? { |mode| SourceModeResolver.xlsx_target_mode?(mode) } || document_types.include?("xlsx_finance")

    nil
  end

  def applied_summary(applied_count, manual_insert_count, patch_payload, final_status)
    prefix =
      case final_status
      when "export_failed" then "Документ сформирован как черновик, но проверка не пройдена"
      when "needs_manual_review" then "Документ сформирован как черновик, требуется дополнительная проверка"
      else "Проект изменений применен"
      end
    inserted_count = patch_payload["inserted_count"].to_i
    [
      "#{prefix}: строк сумм #{applied_count}",
      "DOCX ячеек обновлено #{patch_payload['applied_count'] || 0}",
      ("новых объектов вставлено #{inserted_count}" if inserted_count.positive?),
      ("дополнительная проверка новых объектов #{manual_insert_count}" if manual_insert_count.positive?)
    ].compact.join(". ")
  end

  def amount_items
    @amount_items ||= @change_set.change_items
      .where(change_type: "amount_update")
      .where.not(status: "rejected")
      .where.not(agent_resolution_status: "excluded")
      .includes(:program_node)
      .order(:id)
      .reject { |item| FinancialNodeClassifier.summary_row?(item.program_node) }
  end

  def new_object_items
    @new_object_items ||= @change_set.change_items
      .where(change_type: "new_object")
      .where.not(status: "rejected")
      .where.not(agent_resolution_status: "excluded")
      .order(:id)
  end

  def manual_insert_required_count(new_object_result, patch_result)
    manual_ids = Array(new_object_result["manual_item_ids"])
    skipped_ids = Array(patch_result.payload["skipped_insertions"]).flat_map { |item| Array(item["change_item_ids"]) }
    (manual_ids + skipped_ids).uniq.size
  end

  def source_group_key(item)
    reference = item.source_reference || {}
    reference["group_key"].presence || "#{item.change_type}::#{item.id}"
  end

  def resolve_parent_node(target_version, item)
    reference = item.source_reference || {}
    parsed = parse_external_parent_code(reference["parent_activity_code"].presence || reference["group_key"])
    return nil unless parsed

    candidates = target_version.program_nodes.where(node_type: "activity")
    candidates = candidates.where(code: parsed[:activity_code]) if parsed[:activity_code].present?
    candidates.detect { |node| parent_activity_matches?(node, parsed) } ||
      (parsed[:activity_code].present? && candidates.one? ? candidates.first : nil)
  end

  def parent_activity_matches?(node, parsed)
    subprogram = ancestor_of_type(node, "subprogram")
    subprogram_matches = parsed[:subprogram_display].blank? || subprogram&.display_number.to_s == parsed[:subprogram_display].to_s
    activity_matches = node.code.to_s == parsed[:activity_code].to_s || node.display_number.to_s == parsed[:activity_display].to_s

    subprogram_matches && activity_matches
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

  def ancestor_of_type(node, node_type)
    current = node.parent
    while current
      return current if current.node_type == node_type

      current = current.parent
    end
    nil
  end

  def new_object_name(items)
    first = items.first
    reference = first.source_reference || {}
    name = reference["object_name"].presence || first.new_value.presence || "Новый объект"
    if residual_group?(items) && name.to_s.match?(/\A\d+\z/)
      row_number = reference["row_number"].presence
      return ["Неуказанное направление", ("строка Excel #{row_number}" if row_number)].compact.join(" - ")
    end

    residual_group?(items) ? canonical_residual_name(name) : name
  end

  def residual_group?(items)
    reference = items.first.source_reference || {}
    reference["group_key"].to_s.start_with?("UNASSIGNED_RESIDUAL") ||
      reference["object_code"].to_s == "0000000000.0000000000"
  end

  def virtual_residual_group?(items)
    residual_group?(items) && !visible_residual_group?(items)
  end

  def visible_residual_group?(items)
    return false unless residual_group?(items)

    name = residual_name_for(items)
    normalized = normalize_name(name)
    return false if normalized.include?("сверх объемов")

    normalized == normalize_name("Строительство и реконструкция объектов водоснабжения") ||
      normalized == normalize_name("Строительство (реконструкция) канализационных коллекторов, канализационных насосных станций") ||
      normalized.start_with?(normalize_name("Строительство и реконструкция (модернизация, техническое перевооружение) объектов теплоснабжения муниципальной собственности"))
  end

  def canonical_residual_name(name)
    normalized = normalize_name(name)
    if normalized == normalize_name("Строительство и реконструкция объектов водоснабжения")
      "Строительство и реконструкция объектов водоснабжения муниципальной собственности"
    elsif normalized == normalize_name("Строительство (реконструкция) канализационных коллекторов, канализационных насосных станций")
      "Строительство (реконструкция), канализационных коллекторов, канализационных насосных станций муниципальной собственности"
    elsif normalized.start_with?(normalize_name("Строительство и реконструкция (модернизация, техническое перевооружение) объектов теплоснабжения муниципальной собственности"))
      "Строительство и реконструкция (модернизация, техническое перевооружение) объектов теплоснабжения муниципальной собственности (дополнительные расходы на объекты, включенные в ГП МО)"
    else
      name
    end
  end

  def residual_name_for(items)
    first = items.first
    reference = first.source_reference || {}
    reference["object_name"].presence || first.new_value.presence || ""
  end

  def next_child_display_number(parent)
    prefix = parent.display_number.to_s.sub(/\.+\z/, "")
    if prefix.blank?
      existing_numbers = parent.children.reload.map do |child|
        display = child.display_number.to_s.sub(/\.+\z/, "")
        display.match?(/\A\d+\z/) ? display.to_i : nil
      end.compact
      return ((existing_numbers.max || 0) + 1).to_s
    end

    existing_numbers = parent.children.reload.map do |child|
      display = child.display_number.to_s.sub(/\.+\z/, "")
      next unless display.start_with?("#{prefix}.")

      display.split(".").last.to_i
    end.compact
    next_number = (existing_numbers.max || 0) + 1
    prefix.present? ? "#{prefix}.#{next_number}" : next_number.to_s
  end

  def execution_period_for_items(items)
    years = items.map(&:year).compact.sort
    execution_period_for_years(years)
  end

  def execution_period_for_years(years)
    years = Array(years).compact.sort
    return nil if years.empty?
    return years.first.to_s if years.one?

    "#{years.first}-#{years.last}"
  end

  def execution_period_from_lines(lines)
    years = lines.map(&:year).compact.sort
    return "" if years.empty?
    return years.first.to_s if years.one?

    "#{years.first}-#{years.last}"
  end

  def active_years_for_lines(lines)
    lines.select { |line| BigDecimal(line.amount_rub.to_s).nonzero? }.map(&:year).compact.uniq.sort
  end

  def source_label_for(node, source_type)
    label = context_source_label_for(node, source_type)
    return label if label.present?

    FundingSourceCatalog.label(source_type, organization: @change_set.program_version.municipal_program.organization)
  end

  def context_source_label_for(node, source_type)
    normalized = funding_source_value(source_type)
    [node.parent, *node.parent&.children.to_a].compact.each do |candidate|
      candidate.funding_lines.each do |line|
        next unless funding_source_value(line.source_type) == normalized

        label = line.metadata&.dig("source_label").presence || line.raw_source_name.presence
        return label if label.present? && !FundingSourceCatalog::CANONICAL_KEYS.include?(label.to_s)
      end
    end
    nil
  end

  def source_sort_order(source_type)
    FundingSourceCatalog.sort_order(funding_source_value(source_type))
  end

  def normalize_name(value)
    value.to_s.downcase.tr("Ёё", "ее").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def funding_source_key(raw)
    FundingLine.source_types.key(funding_source_value(raw)) || raw.to_s
  end

  def funding_source_value(raw)
    FundingSourceCatalog.normalize(FundingLine.source_types.fetch(raw.to_s, raw.to_s), organization: @change_set.program_version.municipal_program.organization)
  end
end
