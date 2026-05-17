require "json"
require "net/http"
require "uri"

class OpenRouterIntentClient
  CHAT_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"

  def initialize(
    api_key: ENV["OPENROUTER_API_KEY"],
    endpoint: CHAT_ENDPOINT,
    site_url: ENV["OPENROUTER_SITE_URL"].presence || "http://localhost:3000",
    app_name: ENV["OPENROUTER_APP_NAME"].presence || "Municipal Program Agent",
    transport: HttpTransport.new
  )
    @api_key = api_key.to_s.strip
    @endpoint = endpoint
    @site_url = site_url
    @app_name = app_name
    @transport = transport
  end

  def classify(system_prompt:, user_prompt:, schema:, model:)
    raise OpenRouterModelsClient::Error, "OPENROUTER_API_KEY не настроен" if @api_key.blank?

    payload = {
      model: model,
      messages: [
        { role: "system", content: system_prompt },
        { role: "user", content: user_prompt }
      ],
      temperature: 0,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "municipal_agent_intent",
          strict: true,
          schema: schema
        }
      }
    }

    raw = @transport.post(
      URI(@endpoint),
      body: JSON.generate(payload),
      headers: {
        "Authorization" => "Bearer #{@api_key}",
        "HTTP-Referer" => @site_url,
        "X-OpenRouter-Title" => @app_name,
        "Content-Type" => "application/json"
      }
    )
    content = JSON.parse(raw).fetch("choices").first.fetch("message").fetch("content")
    JSON.parse(content)
  rescue JSON::ParserError => error
    raise OpenRouterModelsClient::Error, "OpenRouter вернул невалидный JSON intent: #{error.message}"
  rescue KeyError, NoMethodError
    raise OpenRouterModelsClient::Error, "OpenRouter response не содержит choices[0].message.content"
  end

  class HttpTransport
    def initialize(open_timeout: 10, read_timeout: 30)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def post(uri, body:, headers:)
      request = Net::HTTP::Post.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = body

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.request(request)
      end
      raise OpenRouterModelsClient::Error, "OpenRouter HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError => error
      raise OpenRouterModelsClient::Error, "OpenRouter недоступен: #{error.message}"
    end
  end
end
