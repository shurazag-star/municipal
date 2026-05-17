require "test_helper"

class AgentIntentEvalSuiteTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "agent-eval@example.com")
    @organization = @user.organization
  end

  test "built-in municipal agent intent eval suite passes all regression cases" do
    result = AgentIntentEvalSuite.new(
      router: AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil),
      context: {
        "procedure" => { "loaded" => true },
        "active_program" => { "loaded" => true, "program_version_id" => 1 },
        "change_sources" => [{ "type" => "xlsx_finance" }]
      }
    ).run

    assert_equal 1.0, result.pass_rate
    assert_empty result.failures
    assert_operator result.cases_count, :>=, 20
  end
end
