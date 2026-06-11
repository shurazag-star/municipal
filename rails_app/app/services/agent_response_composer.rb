class AgentResponseComposer
  FORBIDDEN_REPLACEMENTS = {
    /\bChangeSet\b/ => "проект изменений",
    /parser worker/i => "разбор документов",
    /\bparser\b/i => "разбор документов",
    /\bworker\b/i => "фоновая обработка",
    /post_export_validation/i => "проверка сформированного документа",
    /PROGRAM_TOTAL_DIFF/ => "расхождение контрольных сумм",
    /manual_insert_required/i => "нужно уточнение",
    /INSERTED_IN_DOCX/i => "вставлено в Word-документ",
    /LlmRun/i => "обращение к модели",
    /\bintent\b/i => "задача",
    /tool_call/i => "действие агента",
    /\btool\b/i => "действие",
    /\bmetadata\b/i => "описание",
    /\bJSON\b/i => "данные",
    /LOCAL_BUDGET/ => "местный бюджет",
	    /FEDERAL_BUDGET/ => "федеральный бюджет",
	    /REGIONAL_BUDGET/ => "региональный бюджет",
	    /MOSCOW_OBLAST_BUDGET/ => "бюджет Московской области",
	    /MOSCOW_CITY_BUDGET/ => "бюджет Москвы",
	    /MUNICIPAL_BUDGET/ => "муниципальный бюджет",
	    /EXTRABUDGETARY/ => "внебюджетные средства",
	    /PRIVATE_FUNDS/ => "частные средства",
	    /OTHER_SOURCE/ => "иные источники",
	    /UNKNOWN/ => "источник не определен",
    /export/i => "формирование документа",
    /детерминирован(ный|ная|ное|ные)?/i => "расчетный"
  }.freeze
  FORBIDDEN_TERMS = [
    /\bChangeSet\b/,
    /\bparser\b/i,
    /\bworker\b/i,
    /\bintent\b/i,
    /\btool\b/i,
    /\bmetadata\b/i,
    /post_export_validation/i,
    /manual_insert_required/i,
    /INSERTED_IN_DOCX/i,
    /PROGRAM_TOTAL_DIFF/i,
    /LlmRun/i,
    /\bJSON\b/i,
    /вызов инструмента/i,
    /модуль разбора документов/i,
    /детерминирован/i
  ].freeze

  def self.scrub_content(content)
    text = content.to_s.gsub(
      /DOCX сформирован(?:, но [^.]+)?\..*?Файлы DOCX и отчет доступны на странице проекта изменений\./m,
      "Ранее была попытка сформировать Word-документ. Актуальные готовые файлы я показываю только после проверки документа."
    )
    text = text
      .gsub(/Файл есть в рабочем состоянии:/i, "Вижу в рабочем состоянии:")
      .gsub(/Режим сейчас:/i, "Режим расчета:")
      .gsub(/,\s*статус:\s*([^;.]+)/i) { " (#{$1.strip})" }

    FORBIDDEN_REPLACEMENTS.reduce(text) do |scrubbed, (pattern, replacement)|
      scrubbed.gsub(pattern, replacement)
    end
  end

  def self.forbidden_terms_present?(content)
    FORBIDDEN_TERMS.any? { |pattern| content.to_s.match?(pattern) }
  end

  def initialize(organization:, user:, intent:, tool_result:, routes: Rails.application.routes.url_helpers)
    @organization = organization
    @user = user
    @intent = intent
    @tool_result = tool_result || {}
    @routes = routes
  end

  def compose
    response = case @intent
    when "run_analysis", "create_change_set"
      analysis_response
    when "validate_control_sums"
      control_sum_response
    when "generate_docx", "apply_change_project"
      export_response
    when "show_changeset", "show_change_project"
      change_project_response
    when "show_pending", "show_pending_items"
      pending_response
    when "explain_change"
      explain_change_response
    when "recheck_object"
      targeted_object_response
    when "recalculate_object"
      targeted_object_response
    when "explain_object_change"
      explain_change_response
    when "list_generated_documents", "get_download_links"
      generated_documents_response
    when "search_knowledge_base"
      knowledge_response
    when "compare_sources"
      compare_sources_response
    when "choose_source_priority"
      choose_source_priority_response
    when "check_documents"
      check_documents_response
    when "autonomous_resolution"
      autonomous_resolution_response
    when "confirm_change_items"
      confirm_items_response
    when "approve_change_project"
      approve_project_response
    when "approve_generated_version"
      approve_generated_version_response
    when "smalltalk"
      smalltalk_response
    when "upload_document"
      upload_document_response
    else
      default_response
    end

    response["content"] = scrub_content(response["content"])
    response
  end

  private

  def base(content, cards: [])
    {
      "role" => "assistant",
      "content" => content,
      "cards" => cards
    }
  end

  def analysis_response
    case @tool_result["status"]
    when "completed"
      project_id = @tool_result["change_project_id"] || @tool_result["change_set_id"]
      items_count = @tool_result["change_items_count"].to_i
      unresolved_count = @tool_result["needs_clarification_count"].to_i
      if project_id.present?
        if unresolved_count.positive?
          base("Анализ выполнен. Я подготовил проект изменений №#{project_id}: строк #{items_count}. #{unresolved_count} строк пока не применяю, потому что по ним не хватает данных в документах. Могу показать список.")
        else
          preview = change_items_preview(Array(@tool_result["items"]))
          source = @tool_result["source_mode_label"].presence
          summary = change_summary_text(@tool_result["change_summary"] || {})
          counts = "Сопоставлено: #{@tool_result['resolved_count'].to_i}; исключено из применения: #{@tool_result['excluded_count'].to_i}; уточнений нет."
          base([
            "Анализ выполнен. Я подготовил проект изменений №#{project_id}: строк #{items_count}.",
            source.present? ? "Режим: #{source}." : nil,
            "Применимые строки сопоставлены.",
            counts,
            summary.presence,
            preview.present? ? "Строки изменений:\n#{preview}" : nil,
            "Можно формировать новую редакцию Word-документа."
          ].compact.join("\n\n"))
        end
      else
        diagnostics = @tool_result["diagnostics"] || {}
        if diagnostics["source_document_type"] == "xlsx_finance" &&
            diagnostics["object_groups_count"].to_i.positive? &&
            diagnostics["target_years_count"].to_i.zero? &&
            diagnostics["funding_entries_count"].to_i.zero?
          base("Я проанализировал документы, но проект изменений не создан: Excel-файл вижу и строки мероприятий выделены, однако годовые колонки и суммы финансирования не распознаны. Нужно исправить разбор заголовка Excel, иначе новая редакция будет пустой.")
        elsif diagnostics["source_document_type"] == "xlsx_finance" && diagnostics["object_groups_count"].to_i.zero?
          if diagnostics["program_totals_count"].to_i.zero?
            base("Я проанализировал документы, но проект изменений не создан: Excel-файл вижу, однако в нем не удалось выделить годовые суммы и строки мероприятий или объектов для сопоставления с Word-документом. Это ошибка разбора структуры Excel, а не отсутствие изменений.")
          else
            base("Я проанализировал документы, но проект изменений не создан: контрольные суммы Excel прочитаны, а строки мероприятий или объектов для сопоставления с Word-документом не выделены. Нужно уточнить структуру Excel-разбора, иначе новая редакция будет неполной.")
          end
        elsif diagnostics["matched_count"].to_i.zero? && (diagnostics["unmatched_count"].to_i.positive? || diagnostics["object_groups_count"].to_i.positive?)
          base("Я проанализировал документы, но проект изменений не создан: строки Excel выделены, однако не сопоставились со строками Word-документа. Это проблема сопоставления, а не подтверждение отсутствия изменений.")
        else
          base("Я проанализировал документы. Изменений по суммам не нашел, поэтому проект изменений не создан.")
        end
      end
    when "blocked"
      base("Для анализа не хватает: #{Array(@tool_result['missing']).join(', ')}. Загрузите эти документы, и я подготовлю проект изменений.")
    when "needs_clarification"
      base(@tool_result["clarification_question"].presence || "Нужно уточнить, с какой редакцией продолжить работу.")
    when "failed"
      base("Анализ не выполнен: #{@tool_result['error']}")
    else
      base("Документы вижу. Могу начать анализ изменений или сразу подготовить новую редакцию, если основание уже загружено.")
    end
  end

  def control_sum_response
    items = Array(@tool_result["items"])
    return base("Контрольные суммы пока не рассчитаны. Дождитесь разбора программы и документов-оснований.") if items.empty?

    rows = items.map do |item|
      delta = item["delta_rub"].present? ? ", отклонение #{format_money(item['delta_rub'])} руб." : ""
      word = item["word_amount_rub"].present? ? "в программе #{format_money(item['word_amount_rub'])} руб." : nil
      external = item["external_amount_rub"].present? ? "в документах-основаниях #{format_money(item['external_amount_rub'])} руб." : nil
      amounts = [word, external].compact.join(", ")
      amounts = "#{amounts}, " if amounts.present?
      "#{item['year']}: #{amounts}#{item['status_label'] || item['status']}#{delta}"
    end.join("; ")
    discrepancies = Array(@tool_result["discrepancies"])
    details = if discrepancies.any?
      formatted = discrepancies.first(6).map do |item|
        reference = item["filename"].present? ? " Основание: #{item['filename']}#{item['row_number'].present? ? ", строка #{item['row_number']}" : ""}#{item['page_number'].present? ? ", страница #{item['page_number']}" : ""}." : ""
        "#{item['label']}, #{item['year']}, #{item['source_label'] || item['source_type']}: было #{format_money(item['old_amount_rub'])} руб., стало #{format_money(item['new_amount_rub'])} руб., разница #{format_signed_money(item['delta_rub'])} руб. Причина: #{item['reason']}.#{reference}"
      end.join(" ")
      " Конкретные строки: #{formatted}"
    end
    base("Я проверил контрольные суммы по текущей финансовой модели. #{rows}.#{details}")
  end

  def export_response
    case @tool_result["status"]
    when "completed", "applied"
      cards = download_cards(@tool_result["download_links"]) + action_cards(@tool_result["approval_actions"])
      checks = Array(@tool_result["checks"]).presence || [
        "контрольные суммы сходятся",
        "Word-документ открывается",
        "документ прошел повторный разбор",
        "визуальная проверка пройдена"
      ]
      text = [
        "Готово. Я сформировал проверенный черновик новой редакции муниципальной программы и отчет об изменениях.",
        "Проверки: #{checks.join('; ')}.",
        @tool_result["approval_actions"].present? ? "Чтобы использовать этот документ дальше, утвердите его как актуальную редакцию." : nil,
        export_details
      ].reject(&:blank?).join("\n\n")
      base(text, cards: cards)
    when "needs_manual_review"
      base("Документ подготовлен как черновик, но финальную версию пока не выдаю: остались строки, которые агент не смог надежно разобрать по документам. Напишите: «покажи список».")
    when "needs_clarification"
      items = Array(@tool_result["pending_items"])
      details = items.first(5).map { |item| "#{item['label']}: #{item['reason'] || item['resolution_reason']}" }.join("; ")
      base("Я не применяю часть изменений без достаточного основания. Нужно уточнение по #{@tool_result['needs_clarification_count'].to_i} строкам. #{details.present? ? "Список: #{details}." : "Могу показать список."}")
    when "export_failed"
      first_error = Array(@tool_result["validation_errors"]).first
      message = first_error&.fetch("message", nil) || "проверка документа не пройдена"
      base("Документ сформирован как черновик, но не прошел проверку. #{message}. Финальную версию пока не выдаю.")
    when "blocked"
      missing = Array(@tool_result["missing"])
      if missing.any? { |item| item.to_s.match?(/изменения/) }
        base("В проекте нет изменений, которые можно применить. Сначала проведите анализ или загрузите документы-основания.")
      else
        base("Чтобы сформировать новую редакцию Word-документа, сейчас не хватает: #{missing.join(', ')}.")
      end
    when "failed"
      base("Не удалось сформировать новую редакцию: #{@tool_result['error']}")
    else
      base("Новая редакция формируется после анализа документов, сопоставления изменений и проверок.")
    end
  end

  def change_project_response
    return base("Проект изменений пока не создан. Сначала нужно провести анализ загруженных документов.") if @tool_result["status"] == "empty"

    base("Последний проект изменений №#{@tool_result['change_project_id'] || @tool_result['change_set_id']}: строк #{@tool_result['items_count']}, нужно уточнить #{@tool_result['pending_count']}. Статус: #{@tool_result['status_label'] || @tool_result['change_set_status']}.")
  end

  def pending_response
    return base("Проект изменений пока не создан, поэтому списка для уточнения нет.") if @tool_result["status"] == "empty"

    items = Array(@tool_result["pending_items"])
    manual_count = @tool_result["manual_insert_required_count"].to_i
    return base("В проекте изменений №#{@tool_result['change_project_id'] || @tool_result['change_set_id']} нет строк, которые требуют уточнения. Строк для дополнительной проверки: #{manual_count}.") if items.empty?

    details = items.map do |item|
      "#{item['label']}: #{item['year']}, #{item['source_label'] || item['source_type']}, изменение #{format_signed_money(item['delta_rub'])} руб."
    end.join("; ")
    base("В проекте изменений №#{@tool_result['change_project_id'] || @tool_result['change_set_id']} не применяются без уточнения: #{details}. Строк для дополнительной проверки: #{manual_count}.")
  end

  def explain_change_response
    return base("Проект изменений пока не создан. Сначала нужно провести анализ загруженных документов.") if @tool_result["status"] == "empty"

    items = Array(@tool_result["items"])
    return base("По этому запросу в последнем проекте изменений строк не найдено.") if items.empty?

    details = items.map do |item|
      change_detail(item)
    end.join(" ")
    base("По проекту изменений №#{@tool_result['change_project_id'] || @tool_result['change_set_id']} нашел #{@tool_result['matched_count']} строк: #{details}")
  end

  def targeted_object_response
    return base("Проект изменений пока не создан. Сначала нужно провести анализ загруженных документов.") if @tool_result["status"] == "empty"
    return base("Для проверки нужен конкретный объект.") if @tool_result["status"] == "blocked"
    return base(@tool_result["clarification_question"].presence || "Нужно уточнение для безопасного пересчета.") if @tool_result["status"] == "needs_clarification"
    return manual_batch_change_response if @tool_result["manual_batch_status"].present?
    return manual_object_change_response if @tool_result["manual_change_status"].present?

    items = Array(@tool_result["items"])
    return base("По объекту «#{@tool_result['object_query']}» в последнем проекте изменений строк не найдено.") if items.empty?

    details = items.first(5).map { |item| change_detail(item) }.join(" ")
    recalculation = Array(@tool_result["recalculation"])
    calc_details = recalculation.first(5).map do |row|
      "#{row['year']}: #{row['old_amount_rub']} -> #{row['new_amount_rub']} руб. по #{row['source_type']}"
    end.join("; ")
    suffix = calc_details.present? ? " Пересчет: #{calc_details}." : ""
    base("По объекту «#{@tool_result['object_name'] || @tool_result['object_query']}» нашел #{@tool_result['matched_count']} строк: #{details}.#{suffix}")
  end

  def manual_object_change_response
    if @tool_result["status"] == "needs_confirmation"
      rows = Array(@tool_result["recalculation"]).first(8)
      details = manual_recalculation_lines(rows)
      question = @tool_result["confirmation_question"].presence || "Если все правильно, напишите: «да, формируй готовый DOCX»."
      return base([
        "Я подготовил предварительный расчет по объекту «#{@tool_result['object_name']}».",
        details.any? ? "Изменения:\n#{details.join("\n")}" : nil,
        question
      ].compact.join("\n\n"))
    end

    if @tool_result["status"] == "completed"
      cards = download_cards(@tool_result["download_links"]) + action_cards(@tool_result["approval_actions"])
      rows = Array(@tool_result["recalculation"]).first(5)
      details = manual_recalculation_lines(rows)
      checks = Array(@tool_result["checks"]).presence || ["документ прошел проверку"]
      return base(
        [
          "Я применил изменение по объекту «#{@tool_result['object_name']}» и сформировал проверенный черновик новой редакции.",
          details.any? ? "Изменения:\n#{details.join("\n")}" : nil,
          "Проверки: #{checks.join('; ')}.",
          "Чтобы использовать его дальше, утвердите редакцию."
        ].compact.join("\n\n"),
        cards: cards
      )
    end

    first_error = Array(@tool_result["validation_errors"]).first
    message = first_error&.fetch("message", nil) || Array(@tool_result["missing"]).join(", ").presence || @tool_result["error"]
    base("Изменение по объекту не выпущено в финальную редакцию: #{message}.")
  end

  def manual_batch_change_response
    if @tool_result["status"] == "completed"
      cards = download_cards(@tool_result["download_links"]) + action_cards(@tool_result["approval_actions"])
      details = [
        ("обновлено строк сумм: #{@tool_result['amount_update_items_count']}" if @tool_result["amount_update_items_count"].to_i.positive?),
        ("добавлено строк по новому мероприятию: #{@tool_result['new_object_items_count']}" if @tool_result["new_object_items_count"].to_i.positive?),
        ("обновлено ячеек в Word-документе: #{@tool_result['docx_updated_cells']}" if @tool_result["docx_updated_cells"].to_i.positive?),
        ("вставлено новых объектов: #{@tool_result['docx_inserted_objects']}" if @tool_result["docx_inserted_objects"].to_i.positive?)
      ].compact.join("; ")
      checks = Array(@tool_result["checks"]).presence || ["документ прошел проверку"]
      return base(
        [
          "Я применил пакет ручных изменений и сформировал проверенный черновик новой редакции.",
          details.present? ? "Что изменено: #{details}." : nil,
          "Проверки: #{checks.join('; ')}.",
          "Чтобы использовать его дальше, утвердите редакцию."
        ].compact.join("\n\n"),
        cards: cards
      )
    end

    message = @tool_result["clarification_question"].presence ||
      Array(@tool_result["missing"]).join(", ").presence ||
      @tool_result["error"].presence ||
      "нужно уточнение для безопасного ручного пересчета"
    base("Пакет ручных изменений пока не выпущен в финальную редакцию: #{message}.")
  end

  def generated_documents_response
    documents = Array(@tool_result["documents"])
    return base("Утвержденных редакций пока не вижу. Когда новая редакция пройдет проверки и будет утверждена, она появится в этом списке.") if documents.empty?

    cards = documents.flat_map { |document| download_cards(document["download_links"]) }
    text = "Вижу утвержденные редакции: #{documents.map { |item| "редакция №#{item['change_project_id'] || item['change_set_id']}" }.join(', ')}. Их можно скачать из карточек ниже."
    base(text, cards: cards)
  end

  def knowledge_response
    return base("База знаний по порядку разработки сейчас отключена в настройках агента.") if @tool_result["status"] == "blocked"

    chunks = Array(@tool_result["chunks"])
    return base("В загруженном порядке разработки я не нашел подходящего фрагмента по этому вопросу.") if chunks.empty?

    summary = chunks.first(3).map do |chunk|
      page = chunk["page_number"].present? ? " Страница #{chunk['page_number']}." : ""
      "#{chunk['title']}: #{truncate(chunk['content'])}.#{page}"
    end.join(" ")
    base("По загруженному порядку разработки: #{summary}")
  end

  def compare_sources_response
    conflicts = Array(@tool_result["conflicts"])
    return base("Я сравнил Excel и PDF-основания. Противоречий по одинаковым объектам, годам и источникам не нашел.") if conflicts.empty?

    conflict = conflicts.first
    base("Я нашел расхождение между Excel финансистов и PDF-основанием по объекту «#{conflict['object_name']}», #{conflict['year']} год. Excel: #{format_money(conflict.dig('sources', 'xlsx_finance', 'amount_rub'))} руб. PDF: #{format_money(conflict.dig('sources', 'pdf_agreement', 'amount_rub'))} руб. Нужно выбрать, какой источник применить.")
  end

  def choose_source_priority_response
    return base("Уточните, какой режим применить: Excel как целевую модель, PDF как частичные правки или Excel с PDF как подтверждением.") unless @tool_result["status"] == "completed"

    label = @tool_result["source_mode_label"].presence || (@tool_result["source_priority"] == "xlsx_finance" ? "Excel финансистов" : "PDF-основание")
    rejected = @tool_result["rejected_conflicting_count"].to_i
    base("Принял режим: #{label}. Я обновил проект изменений: конфликтующие строки другого источника исключены#{rejected.positive? ? " (#{rejected})" : ""}. Дальше могу сформировать новую редакцию, если проверки пройдены.")
  end

  def check_documents_response
    matches = Array(@tool_result["matching_documents"])
    documents = Array(@tool_result["documents"])
    source_mode = @tool_result["source_mode"] || {}
    calculation_ids = Array(source_mode["calculation_source_document_ids"]).map(&:to_i)

    if matches.any?
      lines = matches.first(5).map do |document|
        selected = calculation_ids.include?(document["id"].to_i) ? " выбран для расчета" : nil
        "#{document['filename']} — #{document['kind_label']} (#{document['status']})#{selected}"
      end
      unsupported = unsupported_sources_for(matches)
      note = if unsupported.any?
        reasons = unsupported.map { |item| "#{item['filename']}: #{item['reason']}" }.uniq.join("; ")
        " Последний анализ этот файл видел, но не извлек из него структурированные строки изменений: #{reasons}."
      elsif @tool_result.dig("latest_analysis_session", "change_items_count").to_i.zero?
        " Последний анализ по выбранным основаниям завершился без строк изменений."
      end
      return base("Вижу в рабочем состоянии: #{lines.join('; ')}. Режим расчета: #{source_mode['source_mode_label'] || 'не выбран'}.#{note}")
    end

    listed = documents.first(8).map { |document| "#{document['filename']} (#{document['status']})" }.join("; ")
    if listed.present?
      base("Такого файла по запросу не нашел. Сейчас загружены: #{listed}.")
    else
      base("Сейчас в рабочем состоянии нет загруженных документов.")
    end
  end

  def confirm_items_response
    if @tool_result["status"] == "needs_explicit_confirmation"
      count = @tool_result["pending_count"].to_i
      return base("Есть #{count} спорных строк. Полное подтверждение может изменить программу по строкам с низкой уверенностью или конфликтами. Напишите: «подтверждаю все #{count} строк», если хотите продолжить.")
    end
    if @tool_result["status"] == "blocked"
      return base("Пока не могу подтвердить строки: #{Array(@tool_result['missing']).join(', ')}.")
    end

    confirmed = @tool_result["confirmed_count"].to_i
    remaining = @tool_result["pending_count"].to_i
    if remaining.positive?
      base("Я сопоставил строк: #{confirmed}. Осталось уточнить #{remaining}.")
    else
      base("Я сопоставил строки: #{confirmed}. Теперь можно формировать новую редакцию.")
    end
  end

  def approve_project_response
    if @tool_result["status"] == "completed"
      base("Проект изменений №#{@tool_result['change_project_id']} готов к формированию. Теперь я могу сформировать новую редакцию Word-документа.")
    elsif @tool_result["empty_project"]
      base("В проекте нет изменений. Сначала проведите анализ или загрузите документы-основания.")
    else
      base("Проект изменений пока нельзя подтвердить: #{Array(@tool_result['missing']).join(', ')}.")
    end
  end

  def approve_generated_version_response
    if @tool_result["status"] == "approved"
      base("Новая редакция утверждена и теперь используется как активная программа для следующих изменений.")
    elsif @tool_result["status"] == "empty"
      base("Проверенного черновика новой редакции для утверждения сейчас нет.")
    else
      base("Пока не могу утвердить новую редакцию: #{Array(@tool_result['missing']).join(', ')}.")
    end
  end

  def smalltalk_response
    base("Здравствуйте. Я помогу с муниципальной программой: сверю загруженные документы, объясню изменения, проверю контрольные суммы и подготовлю новую редакцию. Напишите задачу обычными словами или прикрепите файл через плюс.")
  end

  def upload_document_response
    filename = @tool_result["filename"].presence || "документ"
    base("Я поставил файл на разбор: #{filename}. Когда разбор завершится, смогу использовать его в анализе и проекте изменений.")
  end

  def unsupported_sources_for(documents)
    ids = documents.map { |document| document["id"].to_i }
    filenames = documents.map { |document| document["filename"].to_s }
    Array(@tool_result["unsupported_sources"]).select do |item|
      ids.include?(item["source_document_id"].to_i) || filenames.include?(item["filename"].to_s)
    end
  end

  def default_response
    base("Я готов помочь с муниципальной программой. Могу проанализировать документы, объяснить изменения по объекту или году, проверить контрольные суммы, показать строки для уточнения и подготовить новую редакцию.")
  end

  def autonomous_resolution_response
    return base("Проект изменений пока не создан. Сначала я должен проанализировать документы.") if @tool_result["status"] == "empty"

    if @tool_result["status"] == "needs_clarification"
      items = Array(@tool_result["pending_items"]).first(5)
      details = items.map { |item| "#{item['label']}: #{item['reason'] || item['resolution_reason']}" }.join("; ")
      return base("Я сопоставил #{@tool_result['resolved_count'].to_i} строк и исключил #{@tool_result['excluded_count'].to_i}. #{@tool_result['needs_clarification_count'].to_i} строк не применяю без уточнения. #{details.present? ? "Список: #{details}." : "Могу показать список."}")
    end

    base("Я сопоставил применимые строки: #{@tool_result['resolved_count'].to_i}. Исключено из применения: #{@tool_result['excluded_count'].to_i}. Можно формировать новую редакцию.")
  end

  def download_cards(links)
    Array(links).select { |link| link["url"].present? }.map do |link|
      {
        "type" => "download",
        "label" => link["label"],
        "url" => link["url"],
        "description" => link["description"]
      }
    end
  end

  def action_cards(actions)
    Array(actions).select { |action| action["url"].present? }.map do |action|
      {
        "type" => "action",
        "label" => action["label"],
        "url" => action["url"],
        "method" => action["method"] || "post",
        "style" => action["style"],
        "description" => action["description"]
      }
    end
  end

  def export_details
    details = []
    details << "Обновлено значений в Word-документе: #{@tool_result['docx_updated_cells'].to_i}" if @tool_result.key?("docx_updated_cells")
    details << "новых объектов вставлено #{@tool_result['docx_inserted_objects'].to_i}" if @tool_result.key?("docx_inserted_objects")
    details << "строк для дополнительной проверки: #{@tool_result['manual_insert_required_count'].to_i}" if @tool_result["manual_insert_required_count"].to_i.positive?
    details.join(", ")
  end

  def change_items_preview(items)
    items.first(8).each_with_index.map { |item, index| "#{index + 1}. #{change_detail(item)}" }.join("\n")
  end

  def change_detail(item)
    hierarchy = item["hierarchy"] || {}
    path = [
      hierarchy["subprogram"],
      hierarchy["main_activity"],
      hierarchy["activity"]
    ].compact.uniq
    path_text = path.any? ? "Раздел: #{path.join(' > ')}. " : ""
    location = source_location(item)
    category = item["category_label"].presence || "изменение"
    "#{category}: #{path_text}#{item['label']}, #{item['year']}, #{item['source_label'] || item['source_type']}: было #{format_money(item['old_amount_rub'])} руб., стало #{format_money(item['new_amount_rub'])} руб., изменение #{format_signed_money(item['delta_rub'])} руб.#{location}"
  end

  def manual_recalculation_lines(rows)
    rows.map do |row|
      "- #{row['year']}, #{source_type_label(row['source_type'])}: было #{format_money(row['old_amount_rub'])} руб., стало #{format_money(row['new_amount_rub'])} руб., изменение #{format_signed_money(row['delta_rub'])} руб."
    end
  end

  def source_type_label(source_type)
    FundingSourceCatalog.label(source_type, organization: @organization)
  rescue StandardError
    source_type.to_s.presence || "источник не определен"
  end

  def change_summary_text(summary)
    summary = summary.to_h
    parts = []
    parts << "изменения существующих объектов: #{summary['object_amount_updates'].to_i}" if summary.key?("object_amount_updates")
    parts << "новые объекты: #{summary['new_objects'].to_i}" if summary.key?("new_objects")
    parts << "остаточные строки Excel: #{summary['residual_adjustments'].to_i}" if summary.key?("residual_adjustments")
    parts << "обнуления по Excel-цели: #{summary['zeroing_updates'].to_i}" if summary.key?("zeroing_updates")
    return nil if parts.empty?

    "Карта изменений: #{parts.join('; ')}."
  end

  def source_location(item)
    location =
      if item["page_number"].present?
        " Основание: страница #{item['page_number']}."
      elsif item["row_number"].present? && item["document_type"].to_s == "xlsx_finance"
        " Основание: строка Excel #{item['row_number']}."
      elsif item["row_number"].present?
        " Основание: строка #{item['row_number']}."
      else
        ""
      end
    location = "#{location} #{truncate(item['evidence_text'], 180)}." if item["evidence_text"].present?
    location
  end

  def scrub_content(content)
    self.class.scrub_content(content)
  end

  def truncate(value, limit = 260)
    text = value.to_s.squish
    return text if text.length <= limit

    "#{text.first(limit).sub(/\s+\S*\z/, '')}..."
  end

  def format_money(value)
    amount = BigDecimal(value.to_s)
    whole, fraction = amount.abs.to_s("F").split(".")
    formatted = whole.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse
    fraction.present? ? "#{formatted},#{fraction.ljust(2, '0').first(2)}" : formatted
  rescue ArgumentError
    "0,00"
  end

  def format_signed_money(value)
    amount = BigDecimal(value.to_s)
    sign = amount.positive? ? "+" : (amount.negative? ? "-" : "")
    "#{sign}#{format_money(amount.abs.to_s('F'))}"
  rescue ArgumentError
    "0,00"
  end
end
