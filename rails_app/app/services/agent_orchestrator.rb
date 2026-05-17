class AgentOrchestrator
  QUICK_ACTION_LABELS = {
    "run_analysis" => "Провести анализ документов",
    "create_change_set" => "Создать проект изменений",
    "validate_control_sums" => "Проверить контрольные суммы",
    "generate_docx" => "Сформировать DOCX"
  }.freeze

  def self.welcome_message(context, audience: nil)
    if audience.to_s == "employee"
      return "Привет, я твой помощник по внесению изменений в муниципальные программы. Загрузите порядок разработки муниципальной программы, текущую редакцию муниципальной программы и, если есть, документ-основание изменений: Excel или PDF. Если документа-основания нет, после загрузки порядка и текущей программы напишите, что именно нужно поменять."
    end

    if !context.dig("procedure", "loaded")
      "Привет! Начнем с настройки вашего муниципалитета. Сначала загрузите порядок разработки и внесения изменений в муниципальные программы. Я сохраню его в базе знаний и буду использовать при проверке программы."
    elsif !context.dig("active_program", "loaded")
      "Порядок разработки уже загружен. Теперь загрузите текущую редакцию муниципальной программы DOCX. Я построю структуру программы и проверю контрольные суммы."
    elsif context.fetch("change_sources", []).empty?
      "Вижу порядок разработки и активную муниципальную программу. Теперь загрузите Excel-отчет финансистов или PDF-соглашение/письмо с изменениями. После этого я подготовлю проект изменений."
    else
      "Вижу порядок разработки, активную муниципальную программу и документы-основания. Могу провести анализ документов или проверить контрольные суммы."
    end
  end

  def initialize(organization:, user:)
    @organization = organization
    @user = user
  end

  def call(content:, quick_action: nil, uploaded_document: nil)
    conversation = AgentConversation.active_for!(
      organization: @organization,
      user: @user,
      audience: @user&.user? ? "employee" : "admin"
    )
    AgentWorkflowRunner.new(organization: @organization, user: @user, conversation: conversation).call(
      content: content,
      quick_action: quick_action,
      uploaded_document: uploaded_document
    )
  end

  private

  def intent_for(decision)
    return nil if decision.intent == "unknown"

    decision.intent
  end

  def record_tool_call(conversation, user_message, quick_action, context, execution_result, decision)
    return nil if quick_action.blank? || quick_action == "smalltalk"

    conversation.agent_tool_calls.create!(
      agent_message: user_message,
      tool_name: tool_name_for(quick_action),
      arguments: {
        quick_action: quick_action,
        intent_source: decision.source,
        intent_confidence: decision.confidence.to_s("F"),
        intent_arguments: decision.arguments
      },
      result: {
        context_summary: context.slice("procedure", "active_program", "change_sources", "latest_analysis_session", "latest_change_set"),
        execution: execution_result
      },
      status: execution_result["status"] == "failed" ? "failed" : "completed",
      error_message: execution_result["error"],
      started_at: Time.current,
      finished_at: Time.current
    )
  end

  def tool_name_for(quick_action)
    case quick_action
    when "run_analysis" then "inspect_ready_for_analysis"
    when "create_change_set" then "create_changeset"
    when "validate_control_sums" then "validate_control_sums"
    when "generate_docx" then "patch_docx"
    when "show_changeset" then "show_changeset"
    when "show_pending" then "show_pending"
    when "explain_change" then "explain_change"
    when "list_generated_documents" then "list_generated_documents"
    when "search_knowledge_base" then "search_knowledge_base"
    when "confirm_change_items" then "confirm_change_items"
    when "approve_change_project" then "approve_change_project"
    when "compare_sources" then "compare_sources"
    when "choose_source_priority" then "choose_source_priority"
    else "chat_context"
    end
  end
end
