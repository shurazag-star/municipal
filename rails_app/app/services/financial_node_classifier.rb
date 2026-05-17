module FinancialNodeClassifier
  module_function

  def concrete_financial_node?(node)
    return false unless node&.node_type.to_s.in?(%w[object residual])
    return false if summary_row?(node)
    return false if virtual_reconciliation_node?(node)

    true
  end

  def summary_row?(node)
    return false unless node

    metadata = node.metadata || {}
    return true if truthy?(metadata["docx_summary_row"]) || truthy?(metadata["summary_row"])

    total_marker?([node.display_number, node.name, node.code].compact.join(" "))
  end

  def total_marker?(value)
    normalized = normalize(value)
    return false if normalized.blank?

    normalized.match?(/\A(?:итого|всего)\b/) || normalized.match?(/\b(?:итого|всего)\s+по\b/)
  end

  def virtual_reconciliation_node?(node)
    metadata = node.metadata || {}
    truthy?(metadata["excel_target_reconciliation"]) ||
      truthy?(metadata["docx_virtual_residual"]) ||
      normalize(node.name).include?("корректировка до целевой модели")
  end

  def summary_target_node(summary_node)
    target_type = summary_target_type(summary_node)
    return summary_node.parent if target_type.blank?

    ancestor_of_type(summary_node, target_type) || summary_node.parent
  end

  def summary_target_type(node)
    normalized = normalize([node&.display_number, node&.name].compact.join(" "))
    return "subprogram" if normalized.match?(/подпрограмм/)
    return "main_activity" if normalized.match?(/основн.*мероприят/)
    return "activity" if normalized.match?(/мероприят/)

    nil
  end

  def ancestor_of_type(node, node_type)
    current = node&.parent
    while current
      return current if current.node_type == node_type

      current = current.parent
    end
    nil
  end

  def normalize(value)
    value.to_s.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def truthy?(value)
    value == true || value.to_s == "true" || value.to_s == "1"
  end
end
