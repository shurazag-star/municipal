require "test_helper"

class SemanticMatchAgentTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "semantic-match@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(organization: @organization, name: "Развитие ЖКХ", period_start_year: 2026, period_end_year: 2030)
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @node = @version.program_nodes.create!(
      node_type: "object",
      name: "Капитальный ремонт ВЗУ Черусти",
      normalized_name: "капитальный ремонт взу черусти",
      display_number: "1.2.3"
    )
  end

  test "selects an existing object only from bounded candidates" do
    client = FakeSemanticClient.new("decision" => "existing_object", "selected_node_id" => @node.id, "confidence" => 0.82, "reason" => "Смысловое совпадение")

    result = SemanticMatchAgent.new(organization: @organization, program_version: @version, llm_client: client)
      .resolve(group: group_with_amounts, candidates: [@node])

    assert_equal "matched", result[:status]
    assert_equal @node, result[:node]
    assert_equal "semantic_agent", result[:source]
    assert_includes client.user_prompt, "999999.00"
    assert_includes client.user_prompt, "candidate_nodes"
  end

  test "persists accepted semantic decision when session context is provided" do
    source_document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "agreement.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    session = @organization.analysis_sessions.create!(
      user: @user,
      program_version: @version,
      source_mode: "pdf_patch",
      summary: { "source_mode" => "pdf_patch" }
    )
    client = FakeSemanticClient.new(
      "decision_type" => "existing_object",
      "selected_program_node_id" => @node.id,
      "confidence" => 0.91,
      "reason" => "Совпадает объект и адрес",
      "evidence" => ["ВЗУ Черусти"],
      "risks" => []
    )

    result = SemanticMatchAgent.new(
      organization: @organization,
      user: @user,
      program_version: @version,
      analysis_session: session,
      source_document: source_document,
      llm_client: client
    ).resolve(group: group_with_amounts, candidates: [@node])

    assert_equal "matched", result[:status]
    decision = AgentMatchDecision.last
    assert_equal session, decision.analysis_session
    assert_equal source_document, decision.source_document
    assert_equal "existing_object", decision.decision_type
    assert_equal "accepted", decision.status
    assert_equal @node, decision.selected_program_node
    assert_equal "pdf_patch", decision.input_snapshot["source_mode"]
  end

  test "rejects invalid node ids returned by LLM" do
    client = FakeSemanticClient.new("decision" => "existing_object", "selected_node_id" => @node.id + 1000, "confidence" => 0.99, "reason" => "bad")

    result = SemanticMatchAgent.new(organization: @organization, program_version: @version, llm_client: client)
      .resolve(group: group_with_amounts, candidates: [@node])

    assert_equal "unresolved", result[:status]
    assert_nil result[:node]
    assert_includes result[:reason], "кандидат"
  end

  test "stays deterministic when LLM client is not configured" do
    result = SemanticMatchAgent.new(organization: @organization, program_version: @version, llm_client: nil)
      .resolve(group: group_with_amounts, candidates: [@node])

    assert_equal "unresolved", result[:status]
    assert_equal "semantic_agent_unavailable", result[:source]
  end

  private

  def group_with_amounts
    {
      "object_name" => "Ремонт водозаборного узла в п. Черусти",
      "object_code" => "",
      "funding_entries" => [{ "year" => 2026, "amount_rub" => "999999.00" }]
    }
  end

  class FakeSemanticClient
    attr_reader :user_prompt

    def initialize(payload)
      @payload = payload
    end

    def classify(system_prompt:, user_prompt:, schema:, model:)
      @user_prompt = user_prompt
      @payload
    end
  end
end
