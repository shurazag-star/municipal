require "bigdecimal"

class ManualInstructionExtractor
  Result = Struct.new(:status, :instruction, :operations, :missing_fields, :clarification_question, keyword_init: true)

  def initialize(organization:, user: nil, llm_client: nil)
    @organization = organization
    @user = user
    @llm_client = llm_client
  end

  def call(text:, context: {})
    original_text = text.to_s.strip
    normalized = normalize(original_text)
    instruction = {
      "source_mode" => "manual_instruction",
      "operation" => operation_from(normalized),
      "subprogram_ref" => extract_ref(original_text, /подпрограмм[аеы]?\s+([0-9а-яa-z .-]+)/i),
      "main_activity_ref" => extract_ref(original_text, /основн[[:alpha:]]*\s+мероприяти[еия]?\s+([0-9а-яa-z .-]+)/i),
      "activity_ref" => extract_activity_ref(original_text),
      "object_ref" => extract_object_ref(original_text),
      "budget_source" => extract_budget_source(normalized),
      "amount_rub" => format_money(extract_money_amount(original_text)),
      "amount_mode" => extract_amount_mode(normalized),
      "text_evidence" => original_text,
      "clarification_status" => "needs_clarification",
      "confidence" => "0.40"
    }.compact
    instruction.merge!(extract_years(normalized, instruction["operation"]))

    missing = missing_fields(instruction, context)
    operations = missing.empty? ? operations_for(instruction) : []
    status = missing.empty? ? "complete" : "needs_clarification"
    instruction["clarification_status"] = status
    instruction["confidence"] = status == "complete" ? "0.92" : "0.40"

    Result.new(
      status: status,
      instruction: instruction,
      operations: operations,
      missing_fields: missing,
      clarification_question: clarification_question(missing, instruction, context)
    )
  end

  private

  def normalize(value)
    value.to_s.downcase.tr("ё", "е").tr(",", ".").gsub(/[[:space:]]+/, " ").strip
  end

  def operation_from(normalized)
    return "transfer" if normalized.match?(/перенес|перенеси|перенос/)
    return "zero" if normalized.match?(/обнул|исключ|убрать финансирован/)
    return "decrease" if normalized.match?(/уменьш|сниз|минус|вычти|сократ/)
    return "increase" if normalized.match?(/увелич|добав|прибав|плюс/)
    return "set_absolute" if normalized.match?(/установ|постав|замен|сделай|должн[ао] стать|новая сумма/)
    return "rename" if normalized.match?(/переимен|измени.*наименован/)

    nil
  end

  def extract_ref(text, pattern)
    match = text.match(pattern)
    return nil unless match

    clean_ref(match[1])
  end

  def extract_activity_ref(text)
    matches = text.scan(/мероприяти[еия]?\s+([0-9]{1,2}(?:[-.][0-9]{1,2})?)/i).flatten
    matches.last.presence
  end

  def extract_object_ref(text)
    patterns = [
      /по\s+объект[ауе]?\s+(.+?)(?::|,|\s+в\s+подпрограмм|\s+в\s+основн|\s+в\s+мероприяти|\s+по\s+(?:местн|муниципал|област|регион|федерал|внебюдж)|\s+с\s+20\d{2}|\s+в\s+20\d{2}|\z)/i,
      /объект[ауе]?\s+(.+?)(?::|,|\s+в\s+подпрограмм|\s+по\s+(?:местн|муниципал|област|регион|федерал|внебюдж)|\s+на\s+\d|\s+в\s+20\d{2}|\z)/i,
      /по\s+(.+?)(?:\s+по\s+(?:местн|муниципал|област|регион|федерал|внебюдж)|\s+с\s+20\d{2}|\s+в\s+20\d{2}|\z)/i
    ]

    patterns.each do |pattern|
      match = text.match(pattern)
      next unless match

      value = clean_object_ref(match[1])
      return value if value.present?
    end
    nil
  end

  def clean_object_ref(value)
    clean_ref(value)
      &.sub(/\A(объект|позици[яюи])\s+/i, "")
      &.sub(/\s+(увелич|уменьш|сниз|добав|прибав|постав|установ|замен|перенес|перенеси)\w*.*\z/i, "")
      &.strip
  end

  def clean_ref(value)
    value.to_s
      .sub(/[.;]\z/, "")
      .sub(/\s+(год[ау]?|руб(?:\.|лей|ля|ль)?).*?\z/i, "")
      .squeeze(" ")
      .strip
      .presence
  end

  def extract_budget_source(normalized)
    return "LOCAL_BUDGET" if normalized.match?(/местн|муниципал/)
    return "REGIONAL_BUDGET" if normalized.match?(/регион|област|субъект/)
    return "FEDERAL_BUDGET" if normalized.match?(/федерал/)
    return "EXTRABUDGETARY" if normalized.match?(/внебюдж/)

    nil
  end

  def extract_amount_mode(normalized)
    return "full_year_balance" if normalized.match?(/вс[ее]\s+финансирован|весь\s+об[ъь]ем|полност\w*\s+финансирован/)

    nil
  end

  def extract_years(normalized, operation)
    if operation == "transfer"
      from_year = normalized[/\bс\s+(20\d{2})\b/, 1]&.to_i
      to_year = normalized[/\b(?:на|в)\s+(20\d{2})\b/, 1]&.to_i
      return { "from_year" => from_year, "to_year" => to_year }.compact
    end

    year = normalized.scan(/\b(20\d{2})\b/).flatten.last
    year.present? ? { "year" => year.to_i } : {}
  end

  def extract_money_amount(text)
    normalized = normalize(text)
    candidates = normalized.to_enum(:scan, /(?<!\d)(\d[\d\s]*(?:\.\d+)?)\s*(млн|миллион(?:ов|а)?|тыс|тысяч(?:а|и)?|руб(?:\.|лей|ля|ль)?|р\b)?/).filter_map do
      match = Regexp.last_match
      raw_amount = match[1]
      unit = match[2]
      compact = raw_amount.gsub(/\s+/, "")
      next if compact.match?(/\A20\d{2}\z/) && unit.blank?
      next if structural_reference_number?(normalized, match.begin(1), compact, unit)

      amount = BigDecimal(compact)
      multiplier =
        if unit.to_s.match?(/млн|миллион/)
          BigDecimal("1000000")
        elsif unit.to_s.match?(/тыс|тысяч/)
          BigDecimal("1000")
        else
          BigDecimal("1")
        end
      amount * multiplier
    rescue ArgumentError
      nil
    end
    candidates.last
  end

  def structural_reference_number?(normalized, start_index, compact, unit)
    return false if unit.present?

    before = normalized[[start_index - 45, 0].max...start_index].to_s
    return true if before.match?(/(?:подпрограмм|основн\w*\s+мероприяти|мероприяти|номер|№)\s*\z/)
    return true if compact.match?(/\A\d{1,2}(?:\.\d{1,2})?\z/) && before.match?(/подпрограмм|мероприяти|номер|№/)

    false
  end

  def format_money(amount)
    return nil unless amount

    format("%.2f", amount)
  end

  def missing_fields(instruction, context)
    missing = []
    missing << "object_ref" if instruction["object_ref"].blank?
    if employee_context?(context) && instruction["object_ref"].present?
      missing << "activity_ref" if instruction["activity_ref"].blank?
      missing << "main_activity_ref" if instruction["main_activity_ref"].blank?
      missing << "subprogram_ref" if instruction["subprogram_ref"].blank?
    end
    missing << "operation" if instruction["operation"].blank?
    missing << "budget_source" if instruction["budget_source"].blank? && instruction["operation"] != "rename"
    full_year_balance = instruction["amount_mode"] == "full_year_balance" && instruction["operation"] == "transfer"
    missing << "amount_rub" if instruction["amount_rub"].blank? && !full_year_balance && !instruction["operation"].in?(%w[zero rename])
    if instruction["operation"] == "transfer"
      missing << "from_year" if instruction["from_year"].blank?
      missing << "to_year" if instruction["to_year"].blank?
    elsif instruction["operation"] != "rename"
      missing << "year" if instruction["year"].blank?
    end
    missing
  end

  def operations_for(instruction)
    if instruction["operation"] == "transfer"
      return [
        operation_payload(instruction, "decrease", instruction["from_year"]),
        operation_payload(instruction, "increase", instruction["to_year"])
      ]
    end

    [operation_payload(instruction, instruction["operation"], instruction["year"])]
  end

  def operation_payload(instruction, operation, year)
    {
      "source_mode" => "manual_instruction",
      "operation" => operation,
      "object_ref" => instruction["object_ref"],
      "budget_source" => instruction["budget_source"],
      "year" => year,
      "amount_rub" => instruction["amount_rub"],
      "amount_mode" => instruction["amount_mode"],
      "text_evidence" => instruction["text_evidence"]
    }.compact
  end

  def clarification_question(missing, instruction, context = {})
    return nil if missing.empty?
    return "Уточните объект или позицию программы, к которой относится изменение." if missing.include?("object_ref")
    if employee_context?(context)
      return "Уточните точный номер и наименование мероприятия, где находится этот объект." if missing.include?("activity_ref")
      return "Уточните точный номер и наименование основного мероприятия." if missing.include?("main_activity_ref")
      return "Уточните номер и наименование муниципальной подпрограммы." if missing.include?("subprogram_ref")
    end
    return "Уточните источник финансирования: местный бюджет, областной/региональный бюджет, федеральный бюджет или иной источник?" if missing.include?("budget_source")
    return "Нужно уточнение: это новая абсолютная сумма, увеличение, уменьшение или перенос между годами?" if missing.include?("operation")
    return "Уточните год изменения." if missing.include?("year")
    return "Уточните годы переноса: с какого года и на какой год перенести сумму?" if missing.include?("from_year") || missing.include?("to_year")
    return "Уточните сумму изменения." if missing.include?("amount_rub")

    "Нужно уточнить данные для безопасного пересчета."
  end

  def employee_context?(context)
    context.to_h["interface_mode"].to_s == "employee"
  end
end
