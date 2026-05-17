require "test_helper"

class AdminOpenrouterSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_user!
    @previous_openrouter_models_client = Rails.application.config.x.openrouter_models_client
    post session_path, params: { email: @user.email, password: "password123" }
  end

  teardown do
    Rails.application.config.x.openrouter_models_client = @previous_openrouter_models_client
  end

  test "admin loads OpenRouter models and saves selected model" do
    AgentSetting.for_organization!(@user.organization)
    Rails.application.config.x.openrouter_models_client = FakeOpenRouterModelsClient.new([
      {
        "id" => "deepseek/deepseek-v4-pro",
        "name" => "DeepSeek: DeepSeek V4 Pro",
        "context_length" => 1_048_576
      },
      {
        "id" => "deepseek/deepseek-v4-flash",
        "name" => "DeepSeek: DeepSeek V4 Flash",
        "context_length" => 1_048_576
      }
    ])

    post load_models_admin_openrouter_settings_path

    assert_redirected_to admin_openrouter_settings_path
    follow_redirect!
    assert_select ".notice", /Загружено моделей: 2/
    assert_select "button", "Загрузить модели"
    assert_select "select[name='openrouter_model_primary'] option[selected][value='deepseek/deepseek-v4-pro']", /DeepSeek V4 Pro/

    @user.organization.reload
    assert_equal "openrouter", @user.organization.settings["openrouter_provider"]
    assert_equal "deepseek/deepseek-v4-pro", @user.organization.settings["openrouter_model_primary"]
    assert_equal 2, @user.organization.settings["openrouter_models"].size

    patch admin_openrouter_settings_path, params: {
      openrouter_model_primary: "deepseek/deepseek-v4-flash",
      openrouter_model_fast: "deepseek/deepseek-v4-flash"
    }

    assert_redirected_to admin_openrouter_settings_path
    @user.organization.reload
    assert_equal "deepseek/deepseek-v4-flash", @user.organization.settings["openrouter_model_primary"]
    assert_equal "deepseek/deepseek-v4-flash", @user.organization.settings["openrouter_model_fast"]
    assert_equal "deepseek/deepseek-v4-flash", @user.organization.agent_setting.reload.primary_model
    assert_equal "deepseek/deepseek-v4-flash", @user.organization.agent_setting.reload.fast_model
  end

  test "chat intent run uses model selected in admin OpenRouter settings" do
    AgentSetting.for_organization!(@user.organization).update!(
      primary_model: "model-a",
      fast_model: "model-a"
    )
    previous_key = ENV["OPENROUTER_API_KEY"]
    original_new = OpenRouterIntentClient.method(:new)
    ENV["OPENROUTER_API_KEY"] = "sk-or-v1-test"
    OpenRouterIntentClient.define_singleton_method(:new) { FakeIntentClient.new }
    patch admin_openrouter_settings_path, params: {
      openrouter_model_primary: "model-b",
      openrouter_model_fast: "model-b"
    }
    assert_redirected_to admin_openrouter_settings_path

    post agent_messages_path, params: { content: "что видишь по загруженному пакету?" }

    assert_equal "model-b", LlmRun.last.model
  ensure
    ENV["OPENROUTER_API_KEY"] = previous_key
    if original_new
      OpenRouterIntentClient.define_singleton_method(:new) do |*args, **kwargs, &block|
        original_new.call(*args, **kwargs, &block)
      end
    end
  end

  test "admin load models ignores an unset config placeholder and builds the real client" do
    Rails.application.config.x.openrouter_models_client = ActiveSupport::OrderedOptions.new
    original_new = OpenRouterModelsClient.method(:new)
    fake_client = FakeOpenRouterModelsClient.new([
      {
        "id" => "deepseek/deepseek-v4-pro",
        "name" => "DeepSeek: DeepSeek V4 Pro",
        "context_length" => 1_048_576
      }
    ])

    OpenRouterModelsClient.define_singleton_method(:new) { fake_client }
    post load_models_admin_openrouter_settings_path

    assert_redirected_to admin_openrouter_settings_path
    @user.organization.reload
    assert_equal "deepseek/deepseek-v4-pro", @user.organization.settings["openrouter_model_primary"]
  ensure
    OpenRouterModelsClient.define_singleton_method(:new) do |*args, **kwargs, &block|
      original_new.call(*args, **kwargs, &block)
    end
  end

  class FakeOpenRouterModelsClient
    def initialize(models)
      @models = models
    end

    def list_models
      @models
    end
  end

  class FakeIntentClient
    def classify(system_prompt:, user_prompt:, schema:, model:)
      {
        "intent" => "run_analysis",
        "arguments" => {},
        "confidence" => 0.99
      }
    end
  end
end
