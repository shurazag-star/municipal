require "test_helper"

class AgentIntentRouterTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "intent-router@example.com")
    @organization = @user.organization
  end

  test "uses LLM structured intent when available" do
    llm = FakeIntentClient.new(
      "intent" => "explain_change",
      "arguments" => { "object_query" => "Черустям" },
      "confidence" => 0.93
    )

    decision = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: llm)
      .route(content: "что поменялось по Черустям", context: workspace_context)

    assert_equal "explain_change", decision.intent
    assert_equal "Черустям", decision.arguments["object_query"]
    assert_equal "llm", decision.source
    assert_equal 1, LlmRun.where(organization: @organization, purpose: "agent_intent").count
    assert_includes llm.system_prompt, AgentSetting.for_organization!(@organization).system_prompt.lines.first.strip
  end

  test "falls back to deterministic intent when LLM is unavailable" do
    decision = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: FailingIntentClient.new)
      .route(content: "подготовь отчет и выгрузи новую редакцию", context: workspace_context)

    assert_equal "generate_docx", decision.intent
    assert_equal "local_rules", decision.source
    assert_operator decision.confidence, :>=, BigDecimal("0.7")
  end

  test "routes manual review and year delta questions" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    pending = router.route(content: "покажи, какие строки требуют ручной проверки", context: workspace_context)
    delta = router.route(content: "почему в 2028 сумма стала больше", context: workspace_context)

    assert_equal "show_pending", pending.intent
    assert_equal "explain_change", delta.intent
    assert_equal 2028, delta.arguments["year"]
  end

  test "routes chat confirmation wording into autonomous document generation" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    confirm_items = router.route(content: "подтверди надежные строки", context: workspace_context)
    approve_project = router.route(content: "подтверди проект изменений", context: workspace_context)

    assert_equal "generate_docx", confirm_items.intent
    assert_equal "generate_docx", approve_project.intent
  end

  test "routes live discrepancy and source priority phrases" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    mismatches = router.route(content: "где несовпадения?", context: workspace_context)
    recalculate = router.route(content: "пересчитай программу", context: workspace_context)
    excel_priority = router.route(content: "используй Excel как главный источник", context: workspace_context)
    auto_priority = router.route(content: "поставь автоматический режим источников", context: workspace_context)

    assert_equal "validate_control_sums", mismatches.intent
    assert_equal "run_analysis", recalculate.intent
    assert_equal "choose_source_priority", excel_priority.intent
    assert_equal "xlsx_finance", excel_priority.arguments["source_priority"]
    assert_equal "xlsx_target", excel_priority.arguments["source_mode"]
    assert_equal "choose_source_priority", auto_priority.intent
    assert_equal "auto", auto_priority.arguments["source_mode"]
  end

  test "routes targeted object recheck and recalculation phrases" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    recalculate = router.route(content: "пересчитай Черусти", context: workspace_context)
    recheck = router.route(content: "перепроверь объект ВЗУ Черусти", context: workspace_context)
    explain = router.route(content: "почему по нему изменилась сумма", context: workspace_context)

    assert_equal "recalculate_object", recalculate.intent
    assert_equal "черусти", recalculate.arguments["object_query"]
    assert_equal "recheck_object", recheck.intent
    assert_equal "explain_object_change", explain.intent
  end

  test "routes manual object amount change from chat" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    decision = router.route(
      content: "по объекту ВЗУ Черусти в 2027 местный бюджет увеличь сумму на 90 млн",
      context: workspace_context
    )

    assert_equal "recalculate_object", decision.intent
    assert_equal "взу черусти", decision.arguments["object_query"]
    assert_equal 2027, decision.arguments["year"]
    assert_equal "LOCAL_BUDGET", decision.arguments["source_type"]
    assert_equal "increase", decision.arguments["amount_operation"]
    assert_equal "90000000.0", BigDecimal(decision.arguments["delta_rub"].to_s).to_s("F")
    assert_equal "manual_instruction", decision.arguments["source_mode"]
  end

  test "routes manual transfer and generated version approval" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    transfer = router.route(
      content: "Перенеси 3 млн по областному бюджету с 2026 на 2028 по объекту ВЗУ Черусти",
      context: workspace_context
    )
    approval = router.route(content: "утверждено, сделай актуальной", context: workspace_context)

    assert_equal "recalculate_object", transfer.intent
    assert_equal "manual_instruction", transfer.arguments["source_mode"]
    assert_equal "approve_generated_version", approval.intent
  end

  test "routes explicit PDF and Excel evidence source modes" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    pdf_only = router.route(content: "используй только PDF-основание", context: workspace_context)
    evidence = router.route(content: "Excel главный, PDF только для проверки", context: workspace_context)
    procedure_only = router.route(
      content: "Используй загруженный Excel как полную целевую финансовую модель, PDF-порядок только как нормативную базу. Проведи анализ, пересчитай бюджет и сформируй новую редакцию DOCX.",
      context: workspace_context
    )

    assert_equal "choose_source_priority", pdf_only.intent
    assert_equal "pdf_patch", pdf_only.arguments["source_mode"]
    assert_equal "pdf_agreement", pdf_only.arguments["source_priority"]
    assert_equal "choose_source_priority", evidence.intent
    assert_equal "xlsx_target_with_pdf_evidence", evidence.arguments["source_mode"]
    assert_equal "xlsx_finance", evidence.arguments["source_priority"]
    assert_equal "generate_docx", procedure_only.intent
    assert_equal "xlsx_target", procedure_only.arguments["source_mode"]
    assert_equal "xlsx_finance", procedure_only.arguments["source_priority"]

    manual = router.route(content: "используй ручной режим из чата", context: workspace_context)
    assert_equal "choose_source_priority", manual.intent
    assert_equal "manual_instruction", manual.arguments["source_mode"]
  end

  test "routes document presence questions to document check intent" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    decision = router.route(content: "Соглашение_по_МБТ_субсидии_с_оттисками_02_09_2025.pdf проверь файл есть?", context: workspace_context)

    assert_equal "check_documents", decision.intent
    assert_equal "local_rules", decision.source
    assert_match(/соглашение.*мбт/i, decision.arguments["document_query"])
  end

  test "routes broad visible documents question without fake file query" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    decision = router.route(content: "какие документы ты видишь?", context: workspace_context)

    assert_equal "check_documents", decision.intent
    assert_equal "local_rules", decision.source
    assert_nil decision.arguments["document_query"]
    assert_nil decision.arguments["object_query"]
  end

  test "routes analysis document command without document-status loop" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    decision = router.route(content: "проанализируй документы", context: workspace_context)

    assert_equal "run_analysis", decision.intent
    assert_equal "local_rules", decision.source
    assert_nil decision.arguments["object_query"]
  end

  test "routes full uploaded files workflow to document generation without fake object query" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    decision = router.route(
      content: "Проанализируй все загруженные файлы, сопоставь строки Excel с текущей редакцией, пересчитай суммы и сформируй новую редакцию Word-документа.",
      context: workspace_context
    )

    assert_equal "generate_docx", decision.intent
    assert_equal "local_rules", decision.source
    assert_nil decision.arguments["object_query"]
    assert_equal "xlsx_target", decision.arguments["source_mode"]
  end

  test "routes broad full document workflow through automatic default when source is not explicit" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    decision = router.route(
      content: "Проанализируй все загруженные файлы, пересчитай суммы и сформируй новую редакцию Word-документа.",
      context: workspace_context
    )

    assert_equal "generate_docx", decision.intent
    assert_nil decision.arguments["object_query"]
    assert_nil decision.arguments["source_mode"]
  end

  test "routes full document workflow with automatic mode phrase to generation" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    decision = router.route(
      content: "Проанализируй все загруженные файлы, автоматически определи способ пересчета, сопоставь финансовую модель с текущей редакцией и сформируй новую редакцию Word-документа.",
      context: workspace_context
    )

    assert_equal "generate_docx", decision.intent
    assert_equal "local_rules", decision.source
    assert_nil decision.arguments["object_query"]
    assert_equal "auto", decision.arguments["source_mode"]
  end

  test "routes generic change request with loaded source to document generation" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    decision = router.route(content: "внеси изменения", context: workspace_context)

    assert_equal "generate_docx", decision.intent
    assert_equal "local_rules", decision.source
    assert_nil decision.arguments["object_query"]
  end

  test "routes generic change request without source to manual instruction flow" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    decision = router.route(content: "внеси изменения", context: workspace_context.merge("change_sources" => []))

    assert_equal "recalculate_object", decision.intent
    assert_equal "manual_instruction", decision.arguments["source_mode"]
    assert_nil decision.arguments["object_query"]
  end

  test "routes approved revision questions to generated documents instead of document check" do
    router = AgentIntentRouter.new(organization: @organization, user: @user, llm_client: nil)

    decision = router.route(content: "есть ли утвержденные редакции?", context: workspace_context)

    assert_equal "list_generated_documents", decision.intent
    assert_equal "local_rules", decision.source
  end

  private

  def workspace_context
    {
      "procedure" => { "loaded" => true },
      "active_program" => { "loaded" => true, "program_version_id" => 1 },
      "change_sources" => [{ "type" => "xlsx_finance" }]
    }
  end

  class FakeIntentClient
    attr_reader :system_prompt

    def initialize(response)
      @response = response
    end

    def classify(system_prompt:, user_prompt:, schema:, model:)
      @system_prompt = system_prompt
      @user_prompt = user_prompt
      @schema = schema
      @model = model
      @response
    end
  end

  class FailingIntentClient
    def classify(**)
      raise OpenRouterModelsClient::Error, "OpenRouter недоступен"
    end
  end
end
