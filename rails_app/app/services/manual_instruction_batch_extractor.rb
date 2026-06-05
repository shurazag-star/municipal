require "bigdecimal"

class ManualInstructionBatchExtractor
  Result = Struct.new(:status, :instructions, :missing_fields, :clarification_question, keyword_init: true)

  def initialize(organization:, user: nil)
    @organization = organization
    @user = user
  end

  def call(text:, context: {})
    original = text.to_s.strip
    return not_batch if original.blank? || !batch_candidate?(original)

    instructions = extract_instructions(original)
    return not_batch if instructions.size < 2

    missing = missing_fields(instructions)
    Result.new(
      status: missing.empty? ? "complete" : "needs_clarification",
      instructions: instructions,
      missing_fields: missing,
      clarification_question: clarification_question(missing)
    )
  end

  private

  def batch_candidate?(text)
    normalized = normalize(text)
    numbered_blocks(text).size >= 2 ||
      normalized.match?(/несколько\s+изменен|пакет\s+изменен|добавить.*новое\s+мероприятие/)
  end

  def extract_instructions(text)
    thousand_units = thousand_rubles?(text)
    numbered_blocks(text).flat_map do |block|
      extract_block_instructions(block, thousand_units)
    end.compact
  end

  def extract_block_instructions(block, thousand_units)
    instructions = []
    if normalize(block).match?(/добавить.*новое\s+мероприятие/)
      new_part, existing_part = block.split(/Существующее\s+мероприятие/i, 2)
      instructions << new_object_instruction(new_part, thousand_units)
      instructions << amount_update_instruction("Существующее мероприятие #{existing_part}", thousand_units) if existing_part.present?
    else
      instructions << amount_update_instruction(block, thousand_units)
    end
    instructions
  end

  def numbered_blocks(text)
    normalized = text.to_s.gsub(/\r\n?/, "\n")
    normalized.scan(/(?:^|\n)\s*\d+\.\s+(.*?)(?=(?:\n\s*\d+\.\s)|\z)/m).flatten.map(&:squish)
  end

  def amount_update_instruction(block, thousand_units)
    amounts = year_amounts(block, thousand_units)
    return nil if amounts.empty?

    {
      "kind" => "amount_update",
      "operation" => "set_absolute",
      "object_ref" => activity_name(block),
      "activity_ref" => activity_ref(block),
      "main_activity_ref" => main_activity_ref(block),
      "subprogram_ref" => subprogram_ref(block),
      "budget_source" => budget_source(block),
      "amounts" => amounts,
      "text_evidence" => block
    }.compact
  end

  def new_object_instruction(block, thousand_units)
    code = block[/нов[[:alpha:]]*\s+мероприяти[ея]\s+(\d{2}\.\d{2})/i, 1] ||
      block[/мероприяти[ея]\s+(\d{2}\.\d{2})/i, 1]
    amounts = year_amounts(block, thousand_units).reject { |row| BigDecimal(row["amount_rub"].to_s).zero? }
    {
      "kind" => "new_object",
      "operation" => "add_object",
      "object_ref" => activity_name(block),
      "activity_code" => code,
      "activity_display" => display_from_activity_code(code),
      "main_activity_ref" => main_activity_ref(block),
      "subprogram_ref" => subprogram_ref(block),
      "budget_source" => budget_source(block),
      "execution_period" => execution_period(block),
      "responsible" => responsible(block),
      "amounts" => amounts,
      "text_evidence" => block
    }.compact
  end

  def year_amounts(block, thousand_units)
    block.scan(/\b(20\d{2})\s*(?:год\s*)?=\s*([0-9\s]+(?:[,.]\d+)?)/i).map do |year, raw_amount|
      {
        "year" => year.to_i,
        "amount_rub" => money(raw_amount, thousand_units).to_s("F")
      }
    end.uniq { |row| row["year"] }
  end

  def activity_name(block)
    quoted = block.scan(/мероприяти[ея]\s+\d{2}\.\d{2}\.?\s*«([^»]+)»/i).flatten.last
    return quoted.squish if quoted.present?

    block[/мероприяти[ея]\s+\d{2}\.\d{2}\.?\s*([^:;.]+)/i, 1]&.squish
  end

  def activity_ref(block)
    code = block.scan(/мероприяти[ея]\s+(\d{2}\.\d{2})/i).flatten.last
    display_from_activity_code(code)
  end

  def main_activity_ref(block)
    block[/основн[[:alpha:]]*\s+мероприяти[ея]\s+\d{2}\.?\s*«([^»]+)»/i, 1]&.squish
  end

  def subprogram_ref(block)
    block[/подпрограмм[аеы]?\s+([^,.;]+)/i, 1]&.squish
  end

  def execution_period(block)
    block[/период\s+([0-9.]{10}\s*-\s*[0-9.]{10})/i, 1]&.delete(" ")
  end

  def responsible(block)
    block[/ответственн[[:alpha:]]*\s+исполнитель:\s*«([^»]+)»/i, 1]&.squish ||
      block[/ответственн[[:alpha:]]*\s+исполнитель:\s*([^.;]+)/i, 1]&.squish
  end

  def budget_source(block)
    explicit = block[/по\s+источнику\s+«([^»]+)»/i, 1].presence || block
    normalized = normalize(explicit)
    return "FEDERAL_BUDGET" if normalized.match?(/федерал/)
    return "REGIONAL_BUDGET" if normalized.match?(/московской\s+области|област|регион|субъект/)
    return "LOCAL_BUDGET" if normalized.match?(/городского\s+округа|местн|муниципал/)

    nil
  end

  def display_from_activity_code(code)
    parts = code.to_s.scan(/\d+/)
    return nil if parts.size < 2

    "#{parts[0].to_i}.#{parts[1].to_i}"
  end

  def thousand_rubles?(text)
    normalize(text).match?(/тыс\.?\s*руб|тысяч/)
  end

  def money(raw, thousand_units)
    value = BigDecimal(raw.to_s.tr(",", ".").gsub(/\s+/, ""))
    thousand_units ? value * BigDecimal("1000") : value
  end

  def missing_fields(instructions)
    instructions.each_with_object([]) do |instruction, missing|
      label = instruction["object_ref"].presence || instruction["activity_code"].presence || "изменение"
      missing << "#{label}: объект" if instruction["object_ref"].blank?
      missing << "#{label}: источник финансирования" if instruction["budget_source"].blank?
      missing << "#{label}: годы и суммы" if Array(instruction["amounts"]).empty?
      if instruction["kind"] == "new_object"
        missing << "#{label}: номер нового мероприятия" if instruction["activity_code"].blank?
        missing << "#{label}: основное мероприятие" if instruction["main_activity_ref"].blank?
      end
    end
  end

  def clarification_question(missing)
    return nil if missing.empty?

    "Уточните данные для ручного пакета изменений: #{missing.first(5).join('; ')}."
  end

  def normalize(value)
    value.to_s.downcase.tr("Ёё", "ее").gsub(/[[:space:]]+/, " ").strip
  end

  def not_batch
    Result.new(status: "not_batch", instructions: [], missing_fields: [], clarification_question: nil)
  end
end
