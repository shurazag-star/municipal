class AgentMemoryService
  MAX_SUMMARY_CHARS = 4_000
  MAX_RECENT_MESSAGES = 10

  def initialize(conversation:)
    @conversation = conversation
  end

  def remember_user_message!(content:, intent:, arguments: {})
    state = working_state.merge(
      "last_user_message" => content.to_s.first(500),
      "last_intent" => intent,
      "last_arguments" => arguments || {},
      "last_task" => task_label(intent),
      "updated_at" => Time.current.iso8601
    )
    if (object = arguments.to_h["object_query"]).present?
      state["last_referenced_object"] = object
      state["last_object_query"] = object
    end
    state["last_source_mode"] = arguments.to_h["source_mode"] if arguments.to_h["source_mode"].present?
    @conversation.update!(working_state: state, memory_updated_at: Time.current)
  end

  def remember_assistant_response!(content:, intent:, tool_results: [], cards: [])
    state = working_state.merge(
      "last_assistant_message" => content.to_s.first(700),
      "last_offered_action" => offered_action(content, intent, tool_results, cards),
      "last_workflow_steps" => Array(tool_results).map { |item| item["intent"] },
      "generated_files_ready" => cards.any?,
      "updated_at" => Time.current.iso8601
    )
    details = referenced_object_details_from_results(tool_results)
    state["last_referenced_object"] ||= details["object_name"]
    state["last_object_name"] = details["object_name"] if details["object_name"].present?
    state["last_program_node_id"] = details["program_node_id"] if details["program_node_id"].present?
    state["last_source_mode"] = details["source_mode"] if details["source_mode"].present?
    state = update_manual_clarification_state(state, tool_results)
    @conversation.update!(
      working_state: state.compact,
      memory_summary: compact_summary(content, state),
      memory_updated_at: Time.current
    )
  end

  private

  def working_state
    @conversation.working_state || {}
  end

  def task_label(intent)
    case intent
    when "generate_docx" then "подготовка новой редакции"
    when "run_analysis", "create_change_set" then "анализ документов"
    when "validate_control_sums" then "проверка контрольных сумм"
    when "show_pending" then "показ строк, которые не удалось разобрать"
    else intent
    end
  end

  def offered_action(content, intent, tool_results, cards)
    text = AgentResponseComposer.scrub_content(content)
    return "choose_version_target" if text.match?(/активн[[:alpha:]]*.*черновик|черновик[[:alpha:]]*.*активн/i)
    return "approve_manual_preview" if Array(tool_results).any? { |item| item.dig("result", "status") == "needs_confirmation" }
    return "list_generated_documents" if cards.any? || text.match?(/скачать|готовые файлы/i)
    return "show_unresolved_items" if text.match?(/показать список|не удалось разобрать|нужно уточнение|строк[аи].*не примен/i)
    return "show_unresolved_items" if intent == "show_pending"
    return "generate_docx" if Array(tool_results).any? { |item| item["intent"] == "generate_docx" }

    nil
  end

  def referenced_object_from_results(tool_results)
    referenced_object_details_from_results(tool_results)["object_name"]
  end

  def referenced_object_details_from_results(tool_results)
    Array(tool_results).each do |item|
      result = item["result"] || {}
      if result["object_name"].present?
        return {
          "object_name" => result["object_name"],
          "program_node_id" => result["program_node_id"],
          "source_mode" => result["source_mode"]
        }.compact
      end
      Array(item.dig("result", "items")).each do |row|
        label = row["label"].presence || row["object_name"].presence
        return {
          "object_name" => label,
          "program_node_id" => row["program_node_id"],
          "source_mode" => result["source_mode"]
        }.compact if label.present?
      end
      Array(item.dig("result", "discrepancies")).each do |row|
        label = row["label"].presence || row["object_name"].presence
        return {
          "object_name" => label,
          "program_node_id" => row["program_node_id"],
          "source_mode" => result["source_mode"]
        }.compact if label.present?
      end
    end
    {}
  end

  def compact_summary(content, state)
    recent = @conversation.agent_messages
      .where(role: %w[user assistant])
      .order(created_at: :desc, id: :desc)
      .limit(MAX_RECENT_MESSAGES)
      .to_a
      .reverse
      .map { |message| "#{message.role}: #{AgentResponseComposer.scrub_content(message.content).squish.first(350)}" }
      .join("\n")
    summary = [
      @conversation.memory_summary,
      "Текущее состояние: #{state.except('last_assistant_message').to_json}",
      "Последний ответ агента: #{AgentResponseComposer.scrub_content(content).squish.first(700)}",
      "Недавний диалог:\n#{recent}"
    ].compact.join("\n\n")
    summary.last(MAX_SUMMARY_CHARS)
  end

  def update_manual_clarification_state(state, tool_results)
    Array(tool_results).each do |item|
      result = item["result"] || {}
      next unless result["source_mode"] == "manual_instruction" || result["manual_change_status"].present?

      if result["status"] == "needs_clarification"
        manual = ManualChangeInstruction.find_by(id: result["manual_instruction_id"])
        state["last_offered_action"] = "resolve_manual_instruction"
        state["pending_manual_instruction_id"] = result["manual_instruction_id"]
        state["pending_manual_missing_fields"] = Array(result["missing"])
        state["unresolved_clarification_question"] = result["clarification_question"]
        state["pending_manual_instruction_text"] = merged_manual_instruction_text(
          state["pending_manual_instruction_text"],
          manual&.text_evidence
        )
      elsif result["status"] == "needs_confirmation"
        state["last_offered_action"] = "approve_manual_preview"
        state["pending_manual_change_set_id"] = result["change_set_id"]
        state["pending_manual_instruction_id"] = result["manual_instruction_id"]
        state["pending_manual_object_name"] = result["object_name"]
      elsif result["status"] == "completed"
        state.except!(
          "pending_manual_instruction_id",
          "pending_manual_missing_fields",
          "unresolved_clarification_question",
          "pending_manual_instruction_text",
          "pending_manual_change_set_id",
          "pending_manual_object_name"
        )
      end
    end

    state
  end

  def merged_manual_instruction_text(previous_text, current_text)
    previous = previous_text.to_s.squish.presence
    current = current_text.to_s.squish.presence
    return current if previous.blank?
    return previous if current.blank?
    return current if current.include?(previous)
    return previous if previous.include?(current)

    [previous, current].join(". ")
  end
end
