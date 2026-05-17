require "test_helper"

class OpenRouterModelsClientTest < ActiveSupport::TestCase
  test "loads and normalizes models from OpenRouter" do
    transport = FakeTransport.new(
      "data" => [
        {
          "id" => "deepseek/deepseek-v4-pro",
          "name" => "DeepSeek: DeepSeek V4 Pro",
          "context_length" => 1_048_576,
          "pricing" => { "prompt" => "0.0000002", "completion" => "0.0000008" },
          "unsupported_internal_field" => "ignored"
        }
      ]
    )

    models = OpenRouterModelsClient.new(api_key: "sk-or-v1-test", transport: transport).list_models

    assert_equal "https://openrouter.ai/api/v1/models", transport.uri.to_s
    assert_equal "Bearer sk-or-v1-test", transport.headers.fetch("Authorization")
    assert_equal [
      {
        "id" => "deepseek/deepseek-v4-pro",
        "name" => "DeepSeek: DeepSeek V4 Pro",
        "context_length" => 1_048_576,
        "pricing" => { "prompt" => "0.0000002", "completion" => "0.0000008" }
      }
    ], models
    assert_equal "deepseek/deepseek-v4-pro", OpenRouterModelsClient.default_primary_model_id(models)
  end

  test "requires configured api key" do
    error = assert_raises(OpenRouterModelsClient::Error) do
      OpenRouterModelsClient.new(api_key: "").list_models
    end

    assert_match(/OPENROUTER_API_KEY/, error.message)
  end

  class FakeTransport
    attr_reader :uri, :headers

    def initialize(payload)
      @payload = payload
    end

    def get(uri, headers:)
      @uri = uri
      @headers = headers
      JSON.generate(@payload)
    end
  end
end
