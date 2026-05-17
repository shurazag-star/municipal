require "test_helper"

class AgentWorkflowRunnerTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "agent-workflow-runner@example.com")
    @organization = @user.organization
    @conversation = AgentConversation.active_for!(organization: @organization, user: @user)
  end

  test "manual clarification answer keeps original instruction text" do
    original_text = "Перенеси всё финансирование с 2027 на 2028 по объекту ВЗУ Черусти"
    manual = ManualChangeInstruction.create!(
      organization: @organization,
      user: @user,
      source_mode: "manual_instruction",
      operation: "transfer",
      text_evidence: original_text,
      clarification_status: "needs_clarification"
    )
    @conversation.update!(
      working_state: {
        "last_offered_action" => "resolve_manual_instruction",
        "pending_manual_instruction_id" => manual.id,
        "pending_manual_instruction_text" => original_text,
        "last_arguments" => { "source_mode" => "manual_instruction" }
      }
    )
    decision = AgentIntentRouter::Decision.new(
      intent: "unknown",
      arguments: {},
      confidence: BigDecimal("0.2"),
      source: "test"
    )

    enriched = AgentWorkflowRunner.new(
      organization: @organization,
      user: @user,
      conversation: @conversation
    ).send(:enrich_decision_with_chat_context, decision, "областной")

    assert_equal "recalculate_object", enriched.intent
    assert_equal "conversation_memory", enriched.source
    assert_includes enriched.arguments["_user_content"], original_text
    assert_includes enriched.arguments["_user_content"], "Уточнение пользователя: областной"
  end

  test "manual clarification memory appends instead of replacing pending instruction" do
    first_manual = ManualChangeInstruction.create!(
      organization: @organization,
      user: @user,
      source_mode: "manual_instruction",
      operation: "transfer",
      text_evidence: "Перенеси всё финансирование с 2027 на 2028 по объекту ВЗУ Черусти",
      clarification_status: "needs_clarification"
    )
    second_manual = ManualChangeInstruction.create!(
      organization: @organization,
      user: @user,
      source_mode: "manual_instruction",
      operation: "unknown",
      text_evidence: "областной",
      clarification_status: "needs_clarification"
    )
    memory = AgentMemoryService.new(conversation: @conversation)

    memory.remember_assistant_response!(
      content: "Уточните источник финансирования",
      intent: "recalculate_object",
      tool_results: [{ "intent" => "recalculate_object", "result" => { "status" => "needs_clarification", "source_mode" => "manual_instruction", "manual_instruction_id" => first_manual.id, "missing" => ["budget_source"] } }],
      cards: []
    )
    memory.remember_assistant_response!(
      content: "Уточните сумму изменения",
      intent: "recalculate_object",
      tool_results: [{ "intent" => "recalculate_object", "result" => { "status" => "needs_clarification", "source_mode" => "manual_instruction", "manual_instruction_id" => second_manual.id, "missing" => ["amount_rub"] } }],
      cards: []
    )

    pending_text = @conversation.reload.working_state["pending_manual_instruction_text"]
    assert_includes pending_text, "Перенеси всё финансирование"
    assert_includes pending_text, "областной"
  end

  test "manual preview confirmation routes to docx generation" do
    @conversation.update!(
      working_state: {
        "last_offered_action" => "approve_manual_preview",
        "pending_manual_change_set_id" => 123
      }
    )
    decision = AgentIntentRouter::Decision.new(
      intent: "smalltalk",
      arguments: {},
      confidence: BigDecimal("0.2"),
      source: "test"
    )

    enriched = AgentWorkflowRunner.new(
      organization: @organization,
      user: @user,
      conversation: @conversation
    ).send(:enrich_decision_with_chat_context, decision, "да, формируй готовый DOCX")

    assert_equal "generate_docx", enriched.intent
    assert_equal "conversation_memory", enriched.source
    assert_equal true, enriched.arguments["manual_preview_confirmed"]
  end
end
