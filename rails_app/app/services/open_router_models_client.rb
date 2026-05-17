require "json"
require "net/http"
require "uri"

class OpenRouterModelsClient
  class Error < StandardError; end

  MODELS_ENDPOINT = "https://openrouter.ai/api/v1/models"
  DEFAULT_PRIMARY_MODEL_ID = "deepseek/deepseek-v4-pro"
  DEFAULT_FAST_MODEL_ID = "deepseek/deepseek-v4-flash"

  def self.configured?
    ENV["OPENROUTER_API_KEY"].present?
  end

  def self.default_primary_model_id(models)
    models = Array(models)
    model_ids = models.map { |model| model["id"] }
    return DEFAULT_PRIMARY_MODEL_ID if model_ids.include?(DEFAULT_PRIMARY_MODEL_ID)

    model_ids.find { |id| id.to_s.match?(/\Adeepseek\/.*v4.*pro/) } || model_ids.first || DEFAULT_PRIMARY_MODEL_ID
  end

  def self.default_fast_model_id(models)
    models = Array(models)
    model_ids = models.map { |model| model["id"] }
    return DEFAULT_FAST_MODEL_ID if model_ids.include?(DEFAULT_FAST_MODEL_ID)

    model_ids.find { |id| id.to_s.match?(/\Adeepseek\/.*flash/) } || default_primary_model_id(models)
  end

  def initialize(
    api_key: ENV["OPENROUTER_API_KEY"],
    endpoint: MODELS_ENDPOINT,
    transport: HttpTransport.new
  )
    @api_key = api_key.to_s.strip
    @endpoint = endpoint
    @transport = transport
  end

  def list_models
    raise Error, "OPENROUTER_API_KEY не настроен" if @api_key.blank?

    payload = JSON.parse(
      @transport.get(
        URI(@endpoint),
        headers: { "Authorization" => "Bearer #{@api_key}" }
      )
    )
    models = payload.fetch("data")
    raise Error, "OpenRouter вернул некорректный список моделей" unless models.is_a?(Array)

    models.map { |model| normalize_model(model) }.sort_by { |model| model.fetch("name").to_s.downcase }
  rescue JSON::ParserError => error
    raise Error, "OpenRouter вернул невалидный JSON: #{error.message}"
  rescue KeyError
    raise Error, "OpenRouter response не содержит data[]"
  end

  private

  def normalize_model(model)
    {
      "id" => model.fetch("id"),
      "name" => model.fetch("name"),
      "context_length" => model["context_length"],
      "pricing" => model["pricing"] || {}
    }
  end

  class HttpTransport
    def get(uri, headers:)
      request = Net::HTTP::Get.new(uri)
      headers.each { |key, value| request[key] = value }

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) do |http|
        http.request(request)
      end
      raise Error, "OpenRouter HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError => error
      raise Error, "OpenRouter недоступен: #{error.message}"
    end
  end
end
