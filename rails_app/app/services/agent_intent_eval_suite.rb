class AgentIntentEvalSuite
  Case = Struct.new(:input, :expected_intent, :required_arguments, keyword_init: true)
  Result = Struct.new(:cases_count, :passed_count, :failures, keyword_init: true) do
    def pass_rate
      return 0.0 if cases_count.zero?

      passed_count.to_f / cases_count
    end
  end

  CASES = [
    Case.new(input: "выгрузи новую редакцию", expected_intent: "generate_docx"),
    Case.new(input: "подготовь отчет", expected_intent: "generate_docx"),
    Case.new(input: "сформируй DOCX", expected_intent: "generate_docx"),
    Case.new(input: "сделай Word файл", expected_intent: "generate_docx"),
    Case.new(input: "скачай новую программу", expected_intent: "generate_docx"),
    Case.new(input: "проанализируй изменения", expected_intent: "run_analysis"),
    Case.new(input: "проведи анализ документов", expected_intent: "run_analysis"),
    Case.new(input: "создай проект изменений", expected_intent: "create_change_set"),
    Case.new(input: "подготовь ChangeSet", expected_intent: "create_change_set"),
    Case.new(input: "проверь контрольные суммы", expected_intent: "validate_control_sums"),
    Case.new(input: "сходятся ли итоги по годам", expected_intent: "validate_control_sums"),
    Case.new(input: "где несовпадения?", expected_intent: "validate_control_sums"),
    Case.new(input: "покажи расхождения", expected_intent: "validate_control_sums"),
    Case.new(input: "почему не сходится 2028 год?", expected_intent: "validate_control_sums", required_arguments: { "year" => 2028 }),
    Case.new(input: "перепроверь суммы", expected_intent: "validate_control_sums"),
    Case.new(input: "сверь программу с Excel", expected_intent: "validate_control_sums"),
    Case.new(input: "пересчитай программу", expected_intent: "run_analysis"),
    Case.new(input: "что поменялось по Черустям", expected_intent: "explain_change", required_arguments: { "object_query" => true }),
    Case.new(input: "почему в 2028 сумма стала больше", expected_intent: "explain_change", required_arguments: { "year" => 2028 }),
    Case.new(input: "объясни изменения по объекту ВЗУ", expected_intent: "explain_change", required_arguments: { "object_query" => true }),
    Case.new(input: "покажи ручную проверку", expected_intent: "show_pending"),
    Case.new(input: "какие строки требуют ручной вставки", expected_intent: "show_pending"),
    Case.new(input: "что спорно и требует подтверждения", expected_intent: "show_pending"),
    Case.new(input: "подтверди надежные строки", expected_intent: "generate_docx"),
    Case.new(input: "подтверди все", expected_intent: "generate_docx"),
    Case.new(input: "подтверждаю все 3 строки", expected_intent: "generate_docx"),
    Case.new(input: "подтверди проект изменений", expected_intent: "generate_docx"),
    Case.new(input: "используй Excel как главный источник", expected_intent: "choose_source_priority"),
    Case.new(input: "применяй PDF-основание как приоритет", expected_intent: "choose_source_priority"),
    Case.new(input: "покажи проект изменений", expected_intent: "show_changeset"),
    Case.new(input: "какой сейчас ChangeSet", expected_intent: "show_changeset"),
    Case.new(input: "какие файлы уже сформированы", expected_intent: "list_generated_documents"),
    Case.new(input: "покажи готовые документы", expected_intent: "list_generated_documents"),
    Case.new(input: "привет", expected_intent: "smalltalk"),
    Case.new(input: "удали все документы и начни заново", expected_intent: "unknown"),
    Case.new(input: "поставь сумму 100 рублей без проверки", expected_intent: "unknown")
  ].freeze

  def initialize(router:, context:, cases: CASES)
    @router = router
    @context = context
    @cases = cases
  end

  def run
    failures = []
    @cases.each do |test_case|
      decision = @router.route(content: test_case.input, context: @context)
      failures << failure_for(test_case, decision) unless passed?(test_case, decision)
    end

    Result.new(
      cases_count: @cases.size,
      passed_count: @cases.size - failures.size,
      failures: failures
    )
  end

  private

  def passed?(test_case, decision)
    return false unless decision.intent == test_case.expected_intent

    test_case.required_arguments.to_h.all? do |key, expected|
      actual = decision.arguments[key]
      expected == true ? actual.present? : actual == expected
    end
  end

  def failure_for(test_case, decision)
    {
      "input" => test_case.input,
      "expected_intent" => test_case.expected_intent,
      "actual_intent" => decision.intent,
      "arguments" => decision.arguments,
      "source" => decision.source,
      "confidence" => decision.confidence.to_s("F")
    }
  end
end
