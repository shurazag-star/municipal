class AgentWorkflowRunner
  QUICK_ACTION_LABELS = AgentOrchestrator::QUICK_ACTION_LABELS

  def initialize(organization:, user:, conversation:)
    @organization = organization
    @user = user
    @conversation = conversation
  end

  def call(content:, quick_action: nil, uploaded_document: nil)
    context = build_context
    decision = AgentIntentRouter.new(organization: @organization, user: @user).route(
      content: content,
      context: context,
      quick_action: quick_action.presence
    )
    decision = enrich_decision_with_chat_context(decision, content)
    intent = intent_for(decision)
    user_message = create_user_message(content, quick_action, decision, intent)
    AgentMemoryService.new(conversation: @conversation).remember_user_message!(
      content: user_message.content,
      intent: intent,
      arguments: decision.arguments
    )

    if uploaded_document.blank? && background_workflow?(intent, content, quick_action)
      return enqueue_background_task(user_message, intent, decision, content, quick_action)
    end

    if uploaded_document&.status == "queued"
      final_intent = "upload_document"
      execution_result = uploaded_document_result(uploaded_document)
      tool_results = []
      refreshed_context = build_context
    else
      tool_results = execute_workflow(user_message, intent, decision, content, context)
      final_intent = tool_results.last&.fetch("intent", nil) || intent
      execution_result = tool_results.last&.fetch("result", nil) || { "status" => "skipped" }
      refreshed_context = build_context
    end

    response = compose_response(
      intent: final_intent,
      tool_result: execution_result,
      tool_results: tool_results,
      context: refreshed_context
    )
    assistant = create_assistant_message(response, decision, quick_action, tool_results, refreshed_context)
    @conversation.update!(context_snapshot: refreshed_context)
    AgentMemoryService.new(conversation: @conversation).remember_assistant_response!(
      content: assistant.content,
      intent: final_intent,
      tool_results: tool_results,
      cards: response["cards"]
    )
    assistant
  end

  def perform_task(task)
    task.update_progress!("Анализирую документы", "Проверяю программу и документы-основания.")
    intent = task.progress_payload["intent"].presence || "generate_docx"
    decision = AgentIntentRouter::Decision.new(
      intent: intent,
      arguments: task.progress_payload["intent_arguments"] || {},
      confidence: BigDecimal(task.progress_payload["intent_confidence"].presence || "1.0"),
      source: task.progress_payload["intent_source"].presence || "background"
    )
    user_message = task.agent_message || @conversation.agent_messages.where(role: "user").order(:id).last
    content = task.input_message.to_s
    initial_context = build_context
    tool_results = execute_workflow(user_message, intent, decision, content, initial_context, task: task)
    final_intent = tool_results.last&.fetch("intent", nil) || intent
    execution_result = tool_results.last&.fetch("result", nil) || { "status" => "skipped" }
    refreshed_context = build_context
    response = compose_response(
      intent: final_intent,
      tool_result: execution_result,
      tool_results: tool_results,
      context: refreshed_context
    )
    assistant = task.assistant_message || @conversation.agent_messages.create!(role: "assistant", content: "Готовлю результат.")
    assistant.update!(
      content: response.fetch("content"),
      metadata: (assistant.metadata || {}).merge(
        intent: final_intent,
        model: refreshed_context.dig("agent_settings", "primary_model"),
        workflow_steps: tool_results.map { |item| item["intent"] },
        cards: response["cards"]
      ).compact
    )
    @conversation.update!(context_snapshot: refreshed_context)
    AgentMemoryService.new(conversation: @conversation).remember_assistant_response!(
      content: assistant.content,
      intent: final_intent,
      tool_results: tool_results,
      cards: response["cards"]
    )
    task.update!(
      result_payload: {
        "intent" => final_intent,
        "execution" => execution_result,
        "workflow_steps" => tool_results.map { |item| item["intent"] }
      }
    )
    assistant
  end

  private

  def build_context
    AgentContextBuilder.new(organization: @organization, user: @user).build.merge(
      "conversation_memory" => {
        "memory_summary" => @conversation.memory_summary,
        "working_state" => @conversation.working_state || {}
      }
    )
  end

  def intent_for(decision)
    return nil if decision.intent == "unknown"

    decision.intent
  end

  def create_user_message(content, quick_action, decision, intent)
    message_content = content.presence || QUICK_ACTION_LABELS.fetch(intent, "Продолжить")
    @conversation.agent_messages.create!(
      role: "user",
      user: @user,
      content: message_content,
      metadata: {
        quick_action: quick_action,
        intent: decision.intent,
        intent_source: decision.source,
        intent_confidence: decision.confidence.to_s("F"),
        intent_arguments: decision.arguments
      }.compact
    )
  end

  def execute_workflow(user_message, intent, decision, content, initial_context, task: nil)
    registry = AgentToolRegistry.new(organization: @organization, user: @user)
    steps_for(intent, content, initial_context).each_with_object([]) do |step, results|
      task&.update_progress!(progress_label_for(step), progress_detail_for(step))
      context = build_context
      arguments = decision.arguments || {}
      user_content = arguments.to_h["_user_content"].presence
      user_content ||= content unless suppress_raw_user_content?(decision, arguments)
      execution_arguments = user_content.present? ? arguments.merge("_user_content" => user_content) : arguments
      result = registry.execute(step, context: context, arguments: execution_arguments)
      results << {
        "intent" => step,
        "result" => result,
        "context" => context
      }
      record_tool_call(user_message, step, context, result, decision)
      break results if stop_workflow?(result)
    end
  end

  def suppress_raw_user_content?(decision, arguments)
    decision.source.to_s == "conversation_memory" &&
      arguments.to_h["source_mode"].to_s == "manual_instruction" &&
      arguments.to_h["version_target"].present? &&
      arguments.to_h["_user_content"].blank?
  end

  def steps_for(intent, content, context)
    return [] if intent.blank? || intent == "smalltalk"

    intent = "generate_docx" if intent == "approve_change_project"

    normalized = normalize_text(content)
    steps = []
    if intent == "generate_docx"
      if !context.dig("latest_change_set", "loaded") ||
          context.dig("latest_change_set", "has_summary_row_updates") ||
          normalized.match?(/анализ|пересчит|свер|проверь|контроль|сумм|расхожд|несовпад|excel|эксел|xlsx/)
        steps << "run_analysis"
      end
      steps << "validate_control_sums" if normalized.match?(/свер|проверь|контроль|сумм|расхожд|несовпад/)
      steps << "autonomous_resolution"
      steps << "generate_docx"
    elsif intent == "run_analysis" && normalized.match?(/свер|проверь|контроль|сумм|расхожд|несовпад/)
      steps << "run_analysis"
      steps << "validate_control_sums"
    elsif intent == "validate_control_sums" && !context.dig("latest_change_set", "loaded")
      steps << "run_analysis"
      steps << "validate_control_sums"
    else
      steps << intent
    end
    steps.uniq
  end

  def stop_workflow?(result)
    result["status"].in?(%w[blocked failed needs_manual_review needs_clarification needs_confirmation export_failed])
  end

  def uploaded_document_result(uploaded_document)
    {
      "status" => "queued_for_parsing",
      "document_id" => uploaded_document.id,
      "filename" => uploaded_document.filename,
      "document_type" => uploaded_document.document_type
    }
  end

  def compose_response(intent:, tool_result:, tool_results:, context:)
    fallback = AgentResponseComposer.new(
      organization: @organization,
      user: @user,
      intent: intent,
      tool_result: tool_result
    ).compose
    AgentAnswerGenerator.new(organization: @organization, user: @user, conversation: @conversation).generate(
      fallback_response: fallback,
      intent: intent,
      tool_results: tool_results,
      context: context
    )
  end

  def create_assistant_message(response, decision, quick_action, tool_results, refreshed_context)
    @conversation.agent_messages.create!(
      role: "assistant",
      content: response.fetch("content"),
      metadata: {
        quick_action: quick_action,
        intent: decision.intent,
        intent_source: decision.source,
        model: refreshed_context.dig("agent_settings", "primary_model"),
        tool_call_id: @conversation.agent_tool_calls.order(:id).last&.id,
        workflow_steps: tool_results.map { |item| item["intent"] },
        cards: response["cards"]
      }.compact
    )
  end

  def record_tool_call(user_message, intent, context, execution_result, decision)
    return nil if intent.blank? || intent == "smalltalk"

    @conversation.agent_tool_calls.create!(
      agent_message: user_message,
      tool_name: tool_name_for(intent),
      arguments: {
        quick_action: intent,
        intent_source: decision.source,
        intent_confidence: decision.confidence.to_s("F"),
        intent_arguments: decision.arguments
      },
      result: {
        context_summary: context.slice("procedure", "active_program", "change_sources", "source_mode", "latest_analysis_session", "latest_change_set"),
        execution: execution_result
      },
      status: execution_result["status"] == "failed" ? "failed" : "completed",
      error_message: execution_result["error"],
      started_at: Time.current,
      finished_at: Time.current
    )
  end

  def tool_name_for(intent)
    case intent
    when "run_analysis" then "inspect_ready_for_analysis"
    when "create_change_set" then "create_changeset"
    when "validate_control_sums" then "validate_control_sums"
    when "generate_docx" then "patch_docx"
    when "show_changeset" then "show_changeset"
    when "show_pending" then "show_pending"
    when "explain_change" then "explain_change"
    when "recheck_object" then "recheck_object"
    when "recalculate_object" then "recalculate_object"
    when "explain_object_change" then "explain_object_change"
    when "list_generated_documents" then "list_generated_documents"
    when "search_knowledge_base" then "search_knowledge_base"
    when "confirm_change_items" then "confirm_change_items"
    when "approve_change_project" then "approve_change_project"
    when "approve_generated_version" then "approve_generated_version"
    when "compare_sources" then "compare_sources"
    when "choose_source_priority" then "choose_source_priority"
    when "check_documents" then "check_documents"
    when "autonomous_resolution" then "autonomous_resolution"
    else "chat_context"
    end
  end

  def background_workflow?(intent, content, quick_action)
    return false unless intent == "generate_docx"
    return true if quick_action == "generate_docx"

    normalize_text(content).match?(/проанализ|сформир|нов.*редакц|docx|word|ворд/)
  end

  def enqueue_background_task(user_message, intent, decision, content, quick_action)
    placeholder = @conversation.agent_messages.create!(
      role: "assistant",
      content: "Принял задачу. Сейчас разберу документы, сопоставлю изменения, пересчитаю суммы и подготовлю результат.",
      metadata: {
        quick_action: quick_action,
        intent: intent,
        cards: []
      }.compact
    )
    task = @conversation.agent_tasks.create!(
      organization: @organization,
      user: @user,
      agent_message: user_message,
      assistant_message: placeholder,
      status: "queued",
      task_type: task_type_for(intent, content),
      input_message: content,
      progress_payload: {
        "intent" => intent,
        "intent_arguments" => decision.arguments,
        "intent_confidence" => decision.confidence.to_s("F"),
        "intent_source" => decision.source,
        "step" => "Задача поставлена в очередь",
        "detail" => "Агент начнет работу в фоне.",
        "updated_at" => Time.current.iso8601
      }
    )
    AgentTaskJob.perform_later(task.id)
    AgentMemoryService.new(conversation: @conversation).remember_assistant_response!(
      content: placeholder.content,
      intent: intent,
      tool_results: [],
      cards: []
    )
    placeholder
  end

  def task_type_for(intent, content)
    return "full_workflow" if intent == "generate_docx" && normalize_text(content).match?(/анализ|пересчит|свер|проверь|контроль|сумм/)
    return "export" if intent == "generate_docx"

    "analysis"
  end

  def progress_label_for(step)
    {
      "run_analysis" => "Анализирую документы",
      "validate_control_sums" => "Проверяю контрольные суммы",
      "autonomous_resolution" => "Сопоставляю изменения",
      "generate_docx" => "Формирую Word-документ и отчет"
    }.fetch(step, "Выполняю задачу")
  end

  def progress_detail_for(step)
    {
      "run_analysis" => "Сверяю текущую программу с документами-основаниями.",
      "validate_control_sums" => "Сравниваю годовые итоги и строки финансирования.",
      "autonomous_resolution" => "Выбираю применимые изменения и исключаю строки без достаточного основания.",
      "generate_docx" => "Пересчитываю дерево программы, обновляю DOCX и запускаю проверки."
    }.fetch(step, "Продолжаю обработку.")
  end

  def normalize_text(text)
    text.to_s.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def enrich_decision_with_chat_context(decision, content)
    decision = enforce_follow_up_action(decision, content)
    decision = enforce_mismatch_intent(decision, content)
    decision = enforce_confirmation_mode(decision, content)
    decision = remove_generic_discrepancy_query(decision, content)
    decision = apply_memory_source_mode(decision, content)
    return decision unless decision&.intent.in?(%w[explain_change validate_control_sums recheck_object recalculate_object explain_object_change])

    arguments = decision.arguments || {}
    query = arguments["object_query"].to_s
    return decision if query.present? && !pronoun_reference?(query)
    return decision unless normalize_text(content).match?(/\b(нему|ней|нем|этом|объекту)\b/)

    object_name = recent_object_name
    return decision if object_name.blank?

    decision.class.new(
      intent: decision.intent,
      arguments: arguments.merge("object_query" => object_name),
      confidence: decision.confidence,
      source: decision.source,
      error: decision.error
    )
  end

  def apply_memory_source_mode(decision, content)
    return decision unless decision&.intent.in?(%w[run_analysis create_change_set generate_docx validate_control_sums compare_sources])

    arguments = decision.arguments || {}
    return decision if arguments["source_mode"].present?

    normalized = normalize_text(content)
    return decision if normalized.match?(/автомат|сам.*опред/)

    state = @conversation.working_state || {}
    return decision unless state["last_source_mode_explicit"]

    source_mode = SourceModeResolver.normalize(state["last_source_mode"])
    return decision if source_mode.blank? || source_mode == "auto"

    decision.class.new(
      intent: decision.intent,
      arguments: arguments.merge("source_mode" => source_mode),
      confidence: decision.confidence,
      source: decision.source,
      error: decision.error
    )
  end

  def enforce_follow_up_action(decision, content)
    normalized = normalize_text(content)
    state = @conversation.working_state || {}
    if state["last_offered_action"] == "resolve_manual_instruction" && manual_clarification_answer?(normalized)
      manual = ManualChangeInstruction.find_by(id: state["pending_manual_instruction_id"], organization: @organization)
      if manual
        previous_text = state["pending_manual_instruction_text"].presence || manual.text_evidence
        combined_text = [previous_text, "Уточнение пользователя: #{content}"].compact.join(". ")
        return decision.class.new(
          intent: "recalculate_object",
          arguments: (state["last_arguments"] || {}).merge(
            "source_mode" => "manual_instruction",
            "_user_content" => combined_text
          ),
          confidence: BigDecimal("0.97"),
          source: "conversation_memory",
          error: decision.error
        )
      end
    end
    if state["last_offered_action"] == "approve_manual_preview" && manual_preview_confirmation?(normalized)
      return decision.class.new(
        intent: "generate_docx",
        arguments: { "source_mode" => "manual_instruction", "manual_preview_confirmed" => true },
        confidence: BigDecimal("0.98"),
        source: "conversation_memory"
      )
    end
    if state["last_offered_action"] == "show_unresolved_items" && normalized.match?(/\A(да|покажи|показать|список|покажи список|да покажи)\z/)
      return decision.class.new(intent: "show_pending", arguments: {}, confidence: BigDecimal("0.97"), source: "conversation_memory")
    end
    if state["last_offered_action"] == "list_generated_documents" && normalized.match?(/\A(да|дай|скачать|файл|дай файл|покажи файл)\z/)
      return decision.class.new(intent: "list_generated_documents", arguments: {}, confidence: BigDecimal("0.97"), source: "conversation_memory")
    end
    if version_choice_follow_up?(state, normalized)
      target = normalized.match?(/черновик/) ? "draft" : "active"
      return decision.class.new(
        intent: state["last_intent"].presence || "recalculate_object",
        arguments: (state["last_arguments"] || {}).merge("version_target" => target),
        confidence: BigDecimal("0.97"),
        source: "conversation_memory"
      )
    end

    decision
  end

  def version_choice_follow_up?(state, normalized)
    return false unless normalized.match?(/\A(в\s+)?(активн[[:alpha:]]*|черновик[[:alpha:]]*)\z/)
    return true if state["last_offered_action"] == "choose_version_target"

    state["last_assistant_message"].to_s.match?(/активн[[:alpha:]]*.*черновик|черновик[[:alpha:]]*.*активн/i)
  end

  def manual_clarification_answer?(normalized)
    normalized.match?(/местн|муниципал|област|регион|федерал|внебюдж|увелич|уменьш|сниз|добав|прибав|постав|установ|замен|перенес|перенос|\b20\d{2}\b|\d/)
  end

  def manual_preview_confirmation?(normalized)
    normalized.match?(/\A(да|ок|окей|все правильно|всё правильно|подтверждаю|формируй|да формируй|готовь|сформируй)(\s|$)/)
  end

  def enforce_mismatch_intent(decision, content)
    normalized = normalize_text(content)
    return decision if decision&.intent == "generate_docx"
    return decision if normalized.match?(/(сформир|подготов|выгруз).*(docx|word|ворд|нов.*редакц|отчет)/)
    return decision unless normalized.match?(/несовпад|расхожд|не сход|свер.*сумм|контрольн.*сумм|перепроверь.*сумм/)

    arguments = (decision&.arguments || {}).dup
    if (year = normalized[/\b(20\d{2})\b/, 1])
      arguments["year"] = year.to_i
    end
    decision.class.new(
      intent: "validate_control_sums",
      arguments: arguments,
      confidence: [decision.confidence, BigDecimal("0.95")].compact.max,
      source: "#{decision.source}_financial_override",
      error: decision.error
    )
  end

  def pronoun_reference?(value)
    normalize_text(value).in?(%w[нему ней нем этом объекту])
  end

  def enforce_confirmation_mode(decision, content)
    return decision unless decision&.intent == "confirm_change_items"

    normalized = normalize_text(content)
    arguments = decision.arguments || {}
    if (match = normalized.match(/подтверждаю\s+все\s+(\d+)/))
      arguments = arguments.merge("confirmation_mode" => "all_confirmed", "expected_count" => match[1].to_i)
    elsif normalized.match?(/подтверд\w*.*все/)
      arguments = arguments.merge("confirmation_mode" => "all_request")
    elsif (ids = normalized.scan(/\b\d+\b/).map(&:to_i).select(&:positive?)).any?
      arguments = arguments.merge("confirmation_mode" => "specific", "change_item_ids" => ids)
    else
      arguments = arguments.merge("confirmation_mode" => "safe")
    end
    decision.class.new(intent: decision.intent, arguments: arguments, confidence: decision.confidence, source: decision.source, error: decision.error)
  end

  def remove_generic_discrepancy_query(decision, content)
    return decision unless decision&.intent == "validate_control_sums"

    normalized = normalize_text(content)
    return decision unless normalized.match?(/несовпад|расхожд|сход/)

    arguments = (decision.arguments || {}).dup
    if arguments["object_query"].to_s.match?(/несовпад|расхожд|сумм|итог|сход/)
      arguments.delete("object_query")
    end
    decision.class.new(intent: decision.intent, arguments: arguments, confidence: decision.confidence, source: decision.source, error: decision.error)
  end

  def recent_object_name
    state = @conversation.working_state || {}
    remembered = state["last_object_name"].presence || state["last_object_query"].presence || state["last_referenced_object"].presence
    return remembered if remembered.present?

    names = recent_change_item_names
    return nil if names.empty?

    text = @conversation.agent_messages
      .where(role: %w[user assistant])
      .order(created_at: :desc, id: :desc)
      .limit(12)
      .pluck(:content)
      .join(" ")
    normalized_text = normalize_text(text)
    names.find do |name|
      normalize_text(name).split.any? { |token| token.length >= 5 && normalized_text.include?(token.first(6)) }
    end
  end

  def recent_change_item_names
    change_set = ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: @organization.id })
      .order(updated_at: :desc)
      .first
    return [] unless change_set

    change_set.change_items.includes(:program_node).map { |item| item.program_node&.name.presence || item.new_value }.compact.uniq
  end
end
