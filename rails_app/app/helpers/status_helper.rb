module StatusHelper
  def human_status(status)
    StatusPresenter.label(status)
  end

  def human_source_type(source_type)
    FundingSourceCatalog.label(source_type)
  end

  def rub_amount(amount)
    return "—" if amount.blank?

    "#{number_with_precision(amount, precision: 2, delimiter: ' ', separator: ',')} ₽"
  end

  def confidence_label(confidence)
    return "—" if confidence.blank?

    "#{number_with_precision(BigDecimal(confidence.to_s) * 100, precision: 1, separator: ',')}%"
  end

  def confirmation_label(change_item)
    return "Агент сопоставил" if change_item.agent_resolution_resolved?
    return "Агент исключил из применения" if change_item.agent_resolution_excluded?
    return "Нужно уточнение" if change_item.agent_resolution_needs_clarification?

    "В работе у агента"
  end

  def agent_tool_label(tool_name)
    {
      "run_analysis" => "Провести анализ документов",
      "inspect_ready_for_analysis" => "Провести анализ документов",
      "create_change_set" => "Создать проект изменений",
      "create_changeset" => "Создать проект изменений",
      "get_or_create_change_project" => "Создать проект изменений",
      "validate_control_sums" => "Проверить контрольные суммы",
      "generate_docx" => "Сформировать DOCX и отчет",
      "patch_docx" => "Сформировать DOCX и отчет",
      "apply_change_project" => "Сформировать DOCX и отчет",
      "show_changeset" => "Показать проект изменений",
      "show_pending" => "Показать строки для уточнения",
      "explain_change" => "Объяснить изменение",
      "list_generated_documents" => "Показать готовые файлы",
      "search_knowledge_base" => "Искать в порядке разработки",
      "confirm_change_items" => "Сопоставить строки",
      "approve_change_project" => "Подготовить к формированию",
      "compare_sources" => "Сравнить Excel и PDF",
      "choose_source_priority" => "Выбрать приоритет источника",
      "autonomous_resolution" => "Сопоставить изменения"
    }.fetch(tool_name.to_s, "Обработать запрос")
  end

  def agent_message_html(content)
    blocks = []
    list_items = []

    flush_list = lambda do
      next if list_items.empty?

      blocks << tag.ul(safe_join(list_items), class: "agent-message-list plain-list")
      list_items = []
    end

    stripped_agent_markdown(content).each_line do |raw_line|
      line = raw_line.strip
      if line.blank?
        flush_list.call
        next
      end

      if line.match?(/\A[-*•]\s+/)
        list_items << tag.li(line.sub(/\A[-*•]\s+/, ""))
      else
        flush_list.call
        blocks << tag.p(line)
      end
    end

    flush_list.call
    safe_join(blocks)
  end

  def stripped_agent_markdown(content)
    content.to_s
      .gsub(/\*\*(.*?)\*\*/m, "\\1")
      .gsub(/__(.*?)__/m, "\\1")
      .gsub(/`([^`]*)`/m, "\\1")
  end
end
