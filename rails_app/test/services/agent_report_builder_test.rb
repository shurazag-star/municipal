require "test_helper"

class AgentReportBuilderTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "agent-builder@example.com")
    @organization = @user.organization
    @organization.update!(
      settings: {
        "openrouter_provider" => "openrouter",
        "openrouter_model_primary" => "deepseek/deepseek-v4-pro"
      }
    )
  end

  test "passes selected organization model to parser worker and stores it on LLM run" do
    parser_client = CapturingParserClient.new

    run = AgentReportBuilder.new(
      organization: @organization,
      user: @user,
      parser_worker_client: parser_client
    ).explain!

    assert_equal "deepseek/deepseek-v4-pro", parser_client.model
    assert_equal "deepseek/deepseek-v4-pro", run.model
  end

  class CapturingParserClient
    attr_reader :model, :mapping_report

    def explain_report(mapping_report, model: nil)
      @mapping_report = mapping_report
      @model = model
      {
        "model" => model,
        "purpose" => "reconciliation_explanation",
        "content" => "Проверка выполнена выбранной моделью."
      }
    end
  end
end
