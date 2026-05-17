require "digest"
require "json"
require "net/http"
require "timeout"
require "uri"

class AgentAnswerGenerator
  CHAT_ENDPOINT = OpenRouterIntentClient::CHAT_ENDPOINT
  FALLBACK_ONLY_INTENTS = %w[run_analysis create_change_set explain_change show_pending].freeze

  def initialize(
    organization:,
    user:,
    transport: nil,
    endpoint: CHAT_ENDPOINT,
    api_key: ENV["OPENROUTER_API_KEY"],
    conversation: nil
  )
    @organization = organization
    @user = user
    @setting = AgentSetting.for_organization!(organization)
    @transport = transport || OpenRouterIntentClient::HttpTransport.new(
      open_timeout: ENV.fetch("OPENROUTER_AGENT_ANSWER_OPEN_TIMEOUT", "5").to_i,
      read_timeout: ENV.fetch("OPENROUTER_AGENT_ANSWER_READ_TIMEOUT", "12").to_i
    )
    @endpoint = endpoint
    @api_key = api_key.to_s.strip
    @conversation = conversation
  end

  def generate(fallback_response:, intent:, tool_results:, context:)
    return fallback_response if fallback_only? || FALLBACK_ONLY_INTENTS.include?(intent.to_s)

    prompt = user_prompt(fallback_response, intent, tool_results, context)
    run = LlmRun.create!(
      organization: @organization,
      user: @user,
      model: @setting.primary_model,
      purpose: "agent_answer",
      prompt_hash: Digest::SHA256.hexdigest("#{system_prompt}\n#{prompt}"),
      input_summary: {
        "intent" => intent,
        "tool_steps" => Array(tool_results).map { |item| item["intent"] }
      },
      status: "running"
    )
    content = Timeout.timeout(answer_timeout_seconds) { request_answer(prompt) }
    content = AgentResponseComposer.scrub_content(content)
    content = AgentResponseComposer.scrub_content(fallback_response.fetch("content")) if AgentResponseComposer.forbidden_terms_present?(content)
    content = AgentResponseComposer.scrub_content(fallback_response.fetch("content")) if content.blank?
    run.update!(status: "completed", output: { "content_preview" => content.first(500) })
    fallback_response.merge("content" => content)
  rescue StandardError => error
    run&.update!(status: "failed", output: { "error" => error.message, "error_class" => error.class.name })
    fallback_response
  end

  private

  def fallback_only?
    Rails.env.test? || @api_key.blank? || @setting.primary_model.blank?
  end

  def answer_timeout_seconds
    ENV.fetch("OPENROUTER_AGENT_ANSWER_TIMEOUT", "15").to_i.clamp(3, 60)
  end

  def request_answer(prompt)
    payload = {
      model: @setting.primary_model,
      messages: [
        { role: "system", content: system_prompt },
        { role: "user", content: prompt }
      ],
      temperature: @setting.temperature.to_f
    }
    raw = @transport.post(
      URI(@endpoint),
      body: JSON.generate(payload),
      headers: {
        "Authorization" => "Bearer #{@api_key}",
        "HTTP-Referer" => ENV["OPENROUTER_SITE_URL"].presence || "http://localhost:3000",
        "X-OpenRouter-Title" => ENV["OPENROUTER_APP_NAME"].presence || "Municipal Program Agent",
        "Content-Type" => "application/json"
      }
    )
    JSON.parse(raw).fetch("choices").first.fetch("message").fetch("content").to_s
  rescue JSON::ParserError => error
    raise OpenRouterModelsClient::Error, "OpenRouter вернул невалидный JSON ответа агента: #{error.message}"
  rescue KeyError, NoMethodError
    raise OpenRouterModelsClient::Error, "OpenRouter response не содержит choices[0].message.content"
  end

  def system_prompt
    <<~PROMPT
      #{@setting.system_prompt}

      Ты формулируешь только финальный ответ пользователю на русском языке.
      Используй только результаты инструментов, которые уже посчитали суммы, сопоставления и проверки.
      Не считай деньги самостоятельно и не придумывай факты.
      Не упоминай внутренние названия инструментов, классы, статусы, JSON, worker, intent, tool, parser, ChangeSet.
      Если документ не прошел проверки или есть строки, которые агент не смог надежно разобрать, не называй файл готовым.
      Ответ должен быть коротким, рабочим и понятным: что сделано, что найдено, что нужно дальше.
    PROMPT
  end

  def user_prompt(fallback_response, intent, tool_results, context)
    JSON.pretty_generate(
      {
        intent: intent,
        fallback_answer: fallback_response.fetch("content"),
        tool_results: Array(tool_results).map { |item| item.slice("intent", "result") },
        workspace: context.slice("procedure", "active_program", "change_sources", "source_mode", "latest_analysis_session", "latest_change_set"),
        memory_summary: @conversation&.memory_summary,
        working_state: @conversation&.working_state,
        chat_history: chat_history
      }
    )
  end

  def chat_history
    return [] unless @setting.use_chat_history? && @conversation

    @conversation.agent_messages
      .where(role: %w[user assistant])
      .order(created_at: :desc, id: :desc)
      .limit(12)
      .to_a
      .reverse
      .map { |message| { role: message.role, content: AgentResponseComposer.scrub_content(message.content).first(700) } }
  end
end
