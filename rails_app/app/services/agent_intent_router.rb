require "digest"
require "json"
require "set"

class AgentIntentRouter
  Decision = Struct.new(:intent, :arguments, :confidence, :source, :error, keyword_init: true)

  ALLOWED_INTENTS = %w[
    run_analysis
    create_change_set
    validate_control_sums
    generate_docx
    show_changeset
    show_pending
    explain_change
    recheck_object
    recalculate_object
    explain_object_change
    list_generated_documents
    search_knowledge_base
    confirm_change_items
    approve_change_project
    approve_generated_version
    compare_sources
    choose_source_priority
    check_documents
    smalltalk
    unknown
  ].freeze

  CONFIDENCE_THRESHOLD = BigDecimal("0.55")

  def initialize(organization:, user:, llm_client: :default)
    @organization = organization
    @user = user
    @setting = AgentSetting.for_organization!(organization)
    @llm_client = llm_client == :default ? default_llm_client : llm_client
  end

  def route(content:, context:, quick_action: nil)
    return decision(quick_action, {}, "1.0", "quick_action") if quick_action.present?

    text = content.to_s.strip
    local_decision = deterministic_decision(text, context)
    return local_decision if local_decision

    llm_decision = route_with_llm(text, context) if @llm_client
    return llm_decision if usable?(llm_decision)

    fallback_decision(text)
  end

  def self.intent_schema
    {
      "type" => "object",
      "properties" => {
        "intent" => {
          "type" => "string",
          "enum" => ALLOWED_INTENTS
        },
        "arguments" => {
          "type" => "object",
          "properties" => {
            "object_query" => { "type" => ["string", "null"] },
            "year" => { "type" => ["integer", "null"] },
            "change_set_id" => { "type" => ["integer", "null"] },
            "change_item_ids" => { "type" => ["array", "null"], "items" => { "type" => "integer" } },
            "confirmation_mode" => { "type" => ["string", "null"], "enum" => ["safe", "specific", "all_request", "all_confirmed", nil] },
            "expected_count" => { "type" => ["integer", "null"] },
            "source_priority" => { "type" => ["string", "null"], "enum" => ["xlsx_finance", "pdf_agreement", nil] },
            "source_mode" => { "type" => ["string", "null"], "enum" => ["auto", "xlsx_target", "pdf_patch", "manual_instruction", "xlsx_target_with_pdf_evidence", "excel_target", "excel_target_with_pdf_evidence", nil] },
            "version_target" => { "type" => ["string", "null"], "enum" => ["active", "draft", nil] },
            "source_type" => { "type" => ["string", "null"] },
            "amount_rub" => { "type" => ["string", "number", "null"] },
            "delta_rub" => { "type" => ["string", "number", "null"] },
            "amount_operation" => { "type" => ["string", "null"], "enum" => ["set", "increase", "decrease", nil] },
            "query" => { "type" => ["string", "null"] },
            "document_query" => { "type" => ["string", "null"] }
          },
          "additionalProperties" => false
        },
        "confidence" => { "type" => "number", "minimum" => 0, "maximum" => 1 }
      },
      "required" => %w[intent arguments confidence],
      "additionalProperties" => false
    }
  end

  private

  def default_llm_client
    return nil unless OpenRouterModelsClient.configured?

    OpenRouterIntentClient.new
  end

  def route_with_llm(text, context)
    model = @setting.fast_model.presence || @setting.primary_model
    input = llm_user_prompt(text, context)
    run = LlmRun.create!(
      organization: @organization,
      user: @user,
      model: model,
      purpose: "agent_intent",
      prompt_hash: Digest::SHA256.hexdigest("#{@setting.system_prompt}\n#{input}"),
      input_summary: {
        "content_preview" => text.first(200),
        "context_keys" => context.keys
      },
      status: "running"
    )

    payload = @llm_client.classify(
      system_prompt: llm_system_prompt,
      user_prompt: input,
      schema: self.class.intent_schema,
      model: model
    )
    normalized = normalize_payload(payload, source: "llm")
    run.update!(status: "completed", output: normalized.to_h)
    normalized
  rescue StandardError => error
    run&.update!(
      status: "failed",
      output: { "error" => error.message, "error_class" => error.class.name }
    )
    decision("unknown", {}, "0.0", "llm_failed", error.message)
  end

  def llm_system_prompt
    <<~PROMPT
      #{@setting.system_prompt}

      Ты не отвечаешь пользователю напрямую на этом шаге. Твоя задача только выбрать один intent из JSON Schema.
      Деньги, суммы и контрольные соотношения не считай. Для финансовых действий выбирай deterministic tool intent.
      Если пользователь просит подготовить новую редакцию, выгрузить DOCX или подготовить отчет, выбирай generate_docx.
      Если пользователь спрашивает, что поменялось, почему изменилась сумма или просит объяснить объект/год, выбирай explain_change.
      Если пользователь просит проверить, перепроверить или пересчитать конкретный объект, выбирай recheck_object или recalculate_object.
      Если пользователь просит изменить, поставить, увеличить, уменьшить или перенести сумму по конкретному объекту текстовой командой, выбирай recalculate_object и source_mode manual_instruction. Извлеки object_query, year/source_type/amount_operation/amount_rub или delta_rub, если это возможно.
      Если пользователь спрашивает почему изменилась сумма по конкретному объекту, выбирай explain_object_change.
      Если пользователь просит список строк, которые не удалось разобрать, выбирай show_pending.
      Если пользователь просит подтвердить строки или проект, не требуй ручного подтверждения: выбирай generate_docx, если он хочет продолжить работу, или show_pending, если он спрашивает о проблемных строках.
      Если пользователь спрашивает про порядок, постановление, согласование, сроки или нормативное основание, выбирай search_knowledge_base.
      Если пользователь спрашивает про противоречия между Excel и PDF, выбирай compare_sources.
      Если пользователь спрашивает про готовые, сформированные, утвержденные или проверенные редакции муниципальной программы, выбирай list_generated_documents.
      Если пользователь спрашивает, загружен ли файл, виден ли документ, разобран ли PDF/Excel/DOCX или доступен ли конкретный документ, выбирай check_documents.
      Если пользователь пишет "утверждено", "сделай актуальной", "принять эту версию" или "используй дальше этот документ", выбирай approve_generated_version.
      Если пользователь выбирает режим Excel/PDF/ручного ввода, выбирай choose_source_priority и заполни source_mode.
      Режимы: xlsx_target — Excel как полная целевая модель; pdf_patch — PDF как частичные правки; manual_instruction — ручной ввод в чате; xlsx_target_with_pdf_evidence — Excel главный, PDF только как подтверждение; auto — выбрать по доступным документам.
      Если уверенности нет, выбирай unknown с низкой confidence.
    PROMPT
  end

  def llm_user_prompt(text, context)
    JSON.pretty_generate(
      {
        user_message: text,
        workspace_context: context.slice("procedure", "active_program", "change_sources", "source_mode", "latest_analysis_session", "latest_change_set", "reconciliation", "conversation_memory"),
        allowed_intents: ALLOWED_INTENTS
      }
    )
  end

  def normalize_payload(payload, source:)
    payload = JSON.parse(payload) if payload.is_a?(String)
    intent = payload["intent"].to_s
    intent = "unknown" unless ALLOWED_INTENTS.include?(intent)
    confidence = BigDecimal(payload["confidence"].to_s)
    arguments = payload["arguments"].is_a?(Hash) ? payload["arguments"].compact : {}
    decision(intent, arguments, confidence, source)
  rescue JSON::ParserError, ArgumentError
    decision("unknown", {}, "0.0", "#{source}_invalid")
  end

  def usable?(decision)
    return false unless decision
    return false if decision.intent == "unknown"

    decision.confidence >= CONFIDENCE_THRESHOLD
  end

  def fallback_decision(text)
    normalized = normalize_text(text)
    arguments = extract_arguments(normalized, text)

    return decision("unknown", arguments, "0.95", "fallback") if normalized.match?(/удали|стереть|очисти.*документ|без проверки|обойди|игнорируй/)
    return decision("approve_generated_version", arguments, "0.95", "fallback") if generated_approval_request?(normalized)
    return decision("choose_source_priority", arguments.merge(source_priority_arguments(normalized)), "0.93", "fallback") if normalized.match?(/(ручн|текстов).*(режим|ввод|чат|источник)/)
    return decision("confirm_change_items", arguments, "0.9", "fallback") if object_clarification_selection?(normalized, arguments)
    return decision("recalculate_object", arguments.merge("source_mode" => "manual_instruction"), "0.92", "fallback") if manual_financial_change?(normalized, arguments)
    return decision("show_pending", arguments, "0.85", "fallback") if normalized.match?(/ручн|спорн|требу\w* уточн|вставк|не примен|не удалось/)
    return decision("validate_control_sums", arguments, "0.9", "fallback") if normalized.match?(/где.*(несовпад|расхожд)|покаж.*расхожд|почему.*(не сход|несовпад|расхожд)|строк.*отлич|контрольн|свер.*сумм|перепроверь.*сумм/)
    return decision("show_changeset", arguments, "0.8", "fallback") if normalized.match?(/покаж.*проект изменений|какой.*changeset|последн.*проект/)
    return decision("list_generated_documents", arguments, "0.9", "fallback") if approved_revision_query?(normalized)
    return decision("check_documents", arguments_without_object_query(arguments).merge(document_query_arguments(normalized)), "0.9", "fallback") if document_status_query?(normalized)
    return decision("recalculate_object", arguments, "0.9", "fallback") if targeted_object_query?(normalized, arguments) && normalized.match?(/пересчит|сформир.*только|нов.*редакц.*только/)
    return decision("recheck_object", arguments, "0.88", "fallback") if targeted_object_query?(normalized, arguments) && normalized.match?(/перепроверь|проверь/)
    return decision("explain_object_change", arguments, "0.88", "fallback") if targeted_object_query?(normalized, arguments) && normalized.match?(/почему|что.*измен|сумм/)
    return decision("generate_docx", arguments, "0.9", "fallback") if normalized.match?(/(подтверд|утверд|согласу)\w*.*проект/)
    if (full_confirm = normalized.match(/подтверждаю\s+все\s+(\d+)/))
      return decision("generate_docx", arguments.merge("expected_count" => full_confirm[1].to_i), "0.9", "fallback")
    end
    return decision("generate_docx", arguments.merge("confirmation_mode" => "all_request"), "0.9", "fallback") if normalized.match?(/подтверд\w*.*все/)
    if normalized.match?(/подтверд\w*.*(строк|надежн|выбранн|изменен)|отметь.*подтвержд/)
      ids = normalized.scan(/\b\d+\b/).map(&:to_i).select(&:positive?)
      mode = ids.any? ? "specific" : "safe"
      return decision("generate_docx", arguments.merge("confirmation_mode" => mode, "change_item_ids" => ids), "0.88", "fallback")
    end
    return decision("generate_docx", arguments.merge(source_priority_arguments(normalized)), "0.9", "fallback") if normalized.match?(/(проанализ|анализ|пересчит).*(сформир|нов.*редакц|docx|word|ворд|отчет)|(сформир|подготов|выгруз).*(нов.*редакц|docx|word|ворд|отчет)/)
    return decision("choose_source_priority", arguments.merge(source_priority_arguments(normalized)), "0.9", "fallback") if normalized.match?(/(excel|эксел|xlsx|pdf|пдф|ручн|текстов).*(главн|приоритет|примен|режим)|используй.*(excel|эксел|xlsx|pdf|пдф|ручн|текстов)|применяй.*(excel|эксел|xlsx|pdf|пдф|ручн|текстов)/)
    return decision("explain_change", arguments, "0.88", "fallback") if normalized.match?(/(покаж|вывед|перечисл|список|какие|что).*(изменен|изменил|изменения|строк)|что\s+нашел/)
    return decision("search_knowledge_base", arguments.merge("query" => text), "0.88", "fallback") if normalized.match?(/поряд|постановл|согласован|срок|основан|можно ли|показател/)
    return decision("compare_sources", arguments, "0.85", "fallback") if normalized.match?(/конфликт|противореч|excel.*pdf|pdf.*excel|сравн.*источник/)
    return decision("validate_control_sums", arguments, "0.9", "fallback") if normalized.match?(/где.*(несовпад|расхожд)|покаж.*расхожд|почему.*(не сход|несовпад|расхожд)|строк.*отлич/)
    return decision("explain_change", arguments, "0.85", "fallback") if normalized.match?(/что поменял|почему|объясн|изменил|стала|стал|стало/)
    return decision("generate_docx", arguments, "0.9", "fallback") if normalized.match?(/выгруз|нов(ую|ая) редакц|подготов.*отчет|сформир.*отчет|скача|docx|ворд|word/)
    return decision("run_analysis", arguments, "0.85", "fallback") if normalized.match?(/проанализ|анализ|пересчит/)
    return decision("show_changeset", arguments, "0.8", "fallback") if normalized.match?(/покаж.*проект изменений|какой.*changeset|последн.*проект/)
    return decision("create_change_set", arguments, "0.85", "fallback") if normalized.match?(/проект изменений|changeset|change set/)
    return decision("validate_control_sums", arguments, "0.85", "fallback") if normalized.match?(/контрольн|свер|сход|несовпад|расхожд|перепроверь.*сумм/)
    return decision("list_generated_documents", arguments, "0.75", "fallback") if normalized.match?(/готов.*файл|сгенерирован|сформирован.*файл|файл.*сформирован|документ/)
    return decision("smalltalk", arguments, "0.65", "fallback") if normalized.match?(/\A(привет|здравств|ок|спасибо)/)

    decision("unknown", arguments, "0.2", "fallback")
  end

  def deterministic_decision(text, context = {})
    normalized = normalize_text(text)
    arguments = extract_arguments(normalized, text)
    command_arguments = arguments_without_object_query(arguments)

    return decision("unknown", arguments, "0.95", "local_rules") if normalized.match?(/удали|стереть|очисти.*документ|без проверки|обойди|игнорируй/)
    return decision("approve_generated_version", arguments, "0.98", "local_rules") if generated_approval_request?(normalized)
    if generic_change_request?(normalized)
      if change_sources_loaded?(context)
        return decision("generate_docx", command_arguments, "0.95", "local_rules")
      end

      return decision("recalculate_object", command_arguments.merge("source_mode" => "manual_instruction"), "0.95", "local_rules")
    end
    return decision("choose_source_priority", arguments.merge(source_priority_arguments(normalized)), "0.97", "local_rules") if normalized.match?(/(ручн|текстов).*(режим|ввод|чат|источник)/)
    return decision("confirm_change_items", arguments, "0.96", "local_rules") if object_clarification_selection?(normalized, arguments)
    return decision("recalculate_object", arguments.merge("source_mode" => "manual_instruction"), "0.96", "local_rules") if manual_financial_change?(normalized, arguments)
    return decision("show_pending", arguments, "0.95", "local_rules") if normalized.match?(/ручн|спорн|требу\w* уточн|вставк|не примен|не удалось|покаж.*спис/)
    return decision("validate_control_sums", arguments, "0.95", "local_rules") if normalized.match?(/где.*(несовпад|расхожд)|покаж.*расхожд|почему.*(не сход|несовпад|расхожд)|строк.*отлич|контрольн.*сумм|свер.*сумм/)
    return decision("show_changeset", arguments, "0.95", "local_rules") if normalized.match?(/покаж.*проект изменений|какой.*changeset|последн.*проект/)
    return decision("list_generated_documents", arguments, "0.95", "local_rules") if approved_revision_query?(normalized)
    return decision("check_documents", command_arguments.merge(document_query_arguments(normalized)), "0.95", "local_rules") if document_status_query?(normalized)
    return decision("recalculate_object", arguments, "0.95", "local_rules") if targeted_object_query?(normalized, arguments) && normalized.match?(/пересчит|сформир.*только|нов.*редакц.*только/)
    return decision("recheck_object", arguments, "0.95", "local_rules") if targeted_object_query?(normalized, arguments) && normalized.match?(/перепроверь|проверь/)
    return decision("explain_object_change", arguments, "0.95", "local_rules") if targeted_object_query?(normalized, arguments) && normalized.match?(/почему|что.*измен|сумм/)
    return decision("explain_change", arguments, "0.95", "local_rules") if normalized.match?(/(покаж|вывед|перечисл|список|какие|что).*(изменен|изменил|изменения|строк)|что\s+нашел/)
    return decision("validate_control_sums", arguments, "0.95", "local_rules") if normalized.match?(/где.*(несовпад|расхожд)|покаж.*расхожд|почему.*(не сход|несовпад|расхожд)|строк.*отлич|контрольн.*сумм|свер.*сумм/)
    return decision("generate_docx", command_arguments.merge(source_priority_arguments(normalized)), "0.95", "local_rules") if normalized.match?(/(проанализ|анализ|пересчит).*(сформир|нов.*редакц|docx|word|ворд|отчет)|(сформир|подготов|выгруз).*(нов.*редакц|docx|word|ворд|отчет)/)
    return decision("choose_source_priority", arguments.merge(source_priority_arguments(normalized)), "0.95", "local_rules") if normalized.match?(/(excel|эксел|xlsx|pdf|пдф|ручн|текстов).*(главн|приоритет|примен|режим)|используй.*(excel|эксел|xlsx|pdf|пдф|ручн|текстов)|применяй.*(excel|эксел|xlsx|pdf|пдф|ручн|текстов)/)
    return decision("generate_docx", arguments, "0.95", "local_rules") if normalized.match?(/(подтверд|утверд|согласу)\w*.*проект|подтверждаю\s+все\s+\d+|подтверд\w*.*(строк|надежн|выбранн|изменен|все)|отметь.*подтвержд/)
    return decision("run_analysis", command_arguments, "0.95", "local_rules") if normalized.match?(/проанализ|анализ/)

    nil
  end

  def generic_change_request?(normalized)
    normalized.match?(/\b(внеси|внесите|внести|примени|применить|сделай|сделать)\b.*\bизменен/)
  end

  def change_sources_loaded?(context)
    context_hash = context.respond_to?(:to_h) ? context.to_h : {}
    sources = context_hash["change_sources"] || context_hash[:change_sources]
    Array(sources).any? do |source|
      next source.present? unless source.respond_to?(:[])

      loaded = source["loaded"] if source.respond_to?(:key?) && source.key?("loaded")
      loaded = source[:loaded] if loaded.nil? && source.respond_to?(:key?) && source.key?(:loaded)
      loaded != false
    end
  end

  def arguments_without_object_query(arguments)
    arguments.to_h.except("object_query")
  end

  def source_priority_arguments(normalized)
    excel = normalized.match?(/excel|эксел|xlsx/)
    pdf = normalized.match?(/pdf|пдф/)
    manual = normalized.match?(/ручн|текстов|из\s+чата|без\s+файл/)
    only = normalized.match?(/только|лишь/)
    evidence = normalized.match?(/подтвержд|провер|поясн|сверк/)
    procedure_pdf = pdf && normalized.match?(/поряд|норматив|регламент|постановл|база/)

    if manual
      { "source_mode" => "manual_instruction" }
    elsif excel && procedure_pdf
      { "source_priority" => "xlsx_finance", "source_mode" => "xlsx_target" }
    elsif excel && pdf && evidence
      { "source_priority" => "xlsx_finance", "source_mode" => "xlsx_target_with_pdf_evidence" }
    elsif pdf && (only || !excel)
      { "source_priority" => "pdf_agreement", "source_mode" => "pdf_patch" }
    elsif excel
      { "source_priority" => "xlsx_finance", "source_mode" => "xlsx_target" }
    elsif normalized.match?(/pdf|пдф/)
      { "source_priority" => "pdf_agreement", "source_mode" => "pdf_patch" }
    else
      {}
    end
  end

  def generated_approval_request?(normalized)
    normalized.match?(/утверждено|сделай\s+актуальн|сделать\s+актуальн|принять\s+(эту\s+)?верси|используй\s+дальше\s+(этот\s+)?документ|утверд\w*.*нов\w*\s+редакц/)
  end

  def extract_arguments(normalized, raw_text = nil)
    arguments = {}
    year = normalized[/\b(20\d{2})\b/, 1]
    arguments["year"] = year.to_i if year
    arguments["version_target"] = "draft" if normalized.match?(/черновик/)
    arguments["version_target"] = "active" if normalized.match?(/активн/)

    object_query = extract_object_query(normalized)
    arguments["object_query"] = object_query if object_query.present? && !object_query.match?(/несовпад|расхожд|сумм|итог/)
    arguments.merge(financial_change_arguments(normalized, raw_text))
  end

  def manual_financial_change?(normalized, arguments)
    return false unless arguments["amount_rub"].present? || arguments["delta_rub"].present?
    return false unless targeted_object_query?(normalized, arguments)
    return false unless normalized.match?(/сумм|руб|млн|тыс|увелич|уменьш|сниз|добав|прибав|плюс|минус|постав|установ|замен|перенес|перенеси|перенос/)

    normalized.match?(/измен|постав|установ|замен|увелич|уменьш|сниз|добав|прибав|плюс|минус|перенес|перенеси|перенос/)
  end

  def financial_change_arguments(normalized, raw_text)
    amount = extract_money_amount(raw_text.presence || normalized)
    return source_type_arguments(normalized) if amount.blank?

    operation = amount_operation(normalized)
    key = operation.in?(%w[increase decrease]) ? "delta_rub" : "amount_rub"
    source_type_arguments(normalized).merge(
      key => amount.to_s("F"),
      "amount_operation" => operation
    )
  end

  def extract_money_amount(text)
    normalized = text.to_s.downcase.tr("ё", "е").tr(",", ".")
    matches = normalized.scan(/(?<!\d)(\d[\d\s]*(?:\.\d+)?)\s*(млн|миллион(?:ов|а)?|тыс|тысяч(?:а|и)?|руб(?:\.|лей|ля|ль)?|р\b)?/)
    candidates = matches.filter_map do |raw_amount, unit|
      compact = raw_amount.gsub(/\s+/, "")
      next if compact.match?(/\A20\d{2}\z/) && unit.blank?

      amount = BigDecimal(compact)
      multiplier =
        if unit.to_s.match?(/млн|миллион/)
          BigDecimal("1000000")
        elsif unit.to_s.match?(/тыс|тысяч/)
          BigDecimal("1000")
        else
          BigDecimal("1")
        end
      amount * multiplier
    rescue ArgumentError
      nil
    end
    candidates.last
  end

  def amount_operation(normalized)
    return "decrease" if normalized.match?(/уменьш|сниз|минус|вычти/)
    return "increase" if normalized.match?(/увелич|добав|прибав|плюс/)

    "set"
  end

  def source_type_arguments(normalized)
    source =
      if normalized.match?(/местн|муниципал/)
        "LOCAL_BUDGET"
      elsif normalized.match?(/регион|област|московск.*област/)
        "REGIONAL_BUDGET"
      elsif normalized.match?(/федерал/)
        "FEDERAL_BUDGET"
      elsif normalized.match?(/внебюдж/)
        "EXTRABUDGETARY"
      end
    source ? { "source_type" => source } : {}
  end

  def targeted_object_query?(normalized, arguments)
    query = arguments["object_query"].to_s
    return true if query.present? && !pronoun_reference?(query) && !generic_object_query?(query)

    normalized.match?(/\b(нему|ней|нем|объекту|позици|черусти|взу|кнс)\b/)
  end

  def object_clarification_selection?(normalized, arguments)
    arguments["object_query"].present? &&
      normalized.match?(/(это|используй|выбери|привяжи|уточняю|нужн\w*)\s+.*(объект|позици)|^(объект|позици)\s+/)
  end

  def generic_object_query?(query)
    normalized = normalize_text(query)
    normalized.blank? ||
      normalized.match?(/\b(программ|бюджет|модел|поряд|основан|норматив|баз|анализ|пересчит|используй|целев|финансов|документ|файл|соглашен|соглашение|строк|ручн|провер|редакц|docx|word|pdf|excel|xlsx)\b/)
  end

  def pronoun_reference?(value)
    value.to_s.match?(/\A(нему|ней|нем|этому|этой|объекту|позиции?)\z/)
  end

  def document_status_query?(normalized)
    return false if normalized.match?(/проанализ|анализ|сформир|подготов|выгруз|нов.*редакц/)
    return false if approved_revision_query?(normalized)

    document_words = /файл|документ|pdf|пдф|excel|эксел|xlsx|docx|ворд|word|соглашен/
    status_words = /есть|вид|загруж|разобран|подключ|доступ|нашел|найд|отображ|появил|проверь/
    normalized.match?(/#{document_words}.*#{status_words}|#{status_words}.*#{document_words}/)
  end

  def approved_revision_query?(normalized)
    revision_words = /редакц|верс/
    ready_words = /утвержден|проверенн|(?<![а-яa-z])готов|сформирован|актуальн|применен|последн/
    question_words = /есть|вид|покаж|какие|список|скач|дай|доступ/
    normalized.match?(/#{ready_words}.*#{revision_words}|#{revision_words}.*#{ready_words}|#{question_words}.*#{revision_words}/)
  end

  def document_query_arguments(normalized)
    return {} if broad_document_overview_query?(normalized)

    query = normalized
      .gsub(/\b(проверь|файл|документ|есть|видно|видишь|загружен|загружена|загружено|разобран|разобрана|подключен|подключена|доступен|доступна|найди|нашел|отображается|pdf|пдф|excel|эксел|xlsx|docx|word|ворд)\b/, " ")
      .squeeze(" ")
      .strip
    query = normalized if query.blank?
    { "document_query" => query }
  end

  def broad_document_overview_query?(normalized)
    normalized.match?(/(какие|какой|что|котор).*?(файл|документ).*?(вид|загруж|есть|доступ|принят|рабоч)|(файл|документ).*?(вид|загруж|есть|доступ|принят|рабоч).*?(какие|какой|что|котор)|что.*загруж|что.*видишь/)
  end

  def extract_object_query(normalized)
    if (match = normalized.match(/\b(?:это|используй|выбери|привяжи|уточняю)\s+(?:объект|позици[яюи])\s+([а-яa-z0-9 ._-]{4,120})/i))
      return sanitize_object_query(match[1])
    end
    if (match = normalized.match(/\b(?:объект|позици[яюи])\s+([а-яa-z0-9 ._-]{4,120})/i))
      return sanitize_object_query(match[1])
    end
    if (match = normalized.match(/\b(?:по|о|об)\s+([а-яa-z0-9 ._-]{4,80})/i))
      return sanitize_object_query(match[1])
    end

    tokens = normalized.split
    important = tokens.find { |token| token.length >= 5 && !stop_words.include?(token) }
    important
  end

  def sanitize_object_query(value)
    value.to_s
      .gsub(/\b(объекту|объект|позиции|позицию)\b/, " ")
      .gsub(/\b(в|на|за)?\s*20\d{2}\b.*\z/, " ")
      .gsub(/\b(местн\w*|муниципал\w*|регион\w*|област\w*|федерал\w*|внебюдж\w*|бюджет\w*)\b.*\z/, " ")
      .gsub(/\b(сумм\w*|измен\w*|постав\w*|установ\w*|замен\w*|увелич\w*|уменьш\w*|сниз\w*|добав\w*|прибав\w*)\b.*\z/, " ")
      .squeeze(" ")
      .strip
  end

  def normalize_text(text)
    text.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def stop_words
    @stop_words ||= %w[
      почему покажи какие строк требуют ручной проверки проверку сумма стала стало больше меньше поменялось
      подготовь отчет выгрузи новую редакцию сформируй проанализируй изменения документы
      пересчитай проверь перепроверь объект объекту позицию позиции нему ней нем поставь установи измени увеличь уменьши
      внеси внесите внести примени применить сделай сделать программа программу бюджет целевую финансовую модель порядок основание файл документ соглашение
    ].flat_map { |words| words.split(/\s+/) }.to_set
  end

  def decision(intent, arguments, confidence, source, error = nil)
    Decision.new(
      intent: intent,
      arguments: arguments || {},
      confidence: BigDecimal(confidence.to_s),
      source: source,
      error: error
    )
  end
end
