require "test_helper"

class ManualInstructionExtractorTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "manual-extractor@example.com")
    @organization = @user.organization
  end

  test "extracts a complete increase instruction with ruble units" do
    result = ManualInstructionExtractor.new(
      organization: @organization,
      user: @user
    ).call(
      text: "Внеси изменения по объекту ВЗУ Черусти: в подпрограмме 1, основном мероприятии 02, мероприятии 02-01 увеличить местный бюджет на 1 млн руб. в 2027 году."
    )

    assert_equal "complete", result.status
    assert_equal "increase", result.instruction["operation"]
    assert_equal "ВЗУ Черусти", result.instruction["object_ref"]
    assert_equal "LOCAL_BUDGET", result.instruction["budget_source"]
    assert_equal 2027, result.instruction["year"]
    assert_equal "1000000.00", result.instruction["amount_rub"]
    assert_equal 1, result.operations.size
  end

  test "extracts transfer as decrease and increase operations" do
    result = ManualInstructionExtractor.new(
      organization: @organization,
      user: @user
    ).call(
      text: "Перенеси 3 млн по областному бюджету с 2026 на 2028 по объекту ВЗУ Черусти."
    )

    assert_equal "complete", result.status
    assert_equal "transfer", result.instruction["operation"]
    assert_equal 2026, result.instruction["from_year"]
    assert_equal 2028, result.instruction["to_year"]
    assert_equal "3000000.00", result.instruction["amount_rub"]
    assert_equal %w[decrease increase], result.operations.map { |operation| operation["operation"] }
    assert_equal [2026, 2028], result.operations.map { |operation| operation["year"] }
  end

  test "does not treat structural program numbers as manual amount" do
    result = ManualInstructionExtractor.new(
      organization: @organization,
      user: @user
    ).call(
      text: "объект называется «Строительство водозаборного узла в поселке Мещерский Бор городского округа Шатура». Всё финансирование с 2027 года надо перенести на 2028 год. Этот объект находится в мероприятии 02.01, основное мероприятие 02, подпрограмма номер 1 «Чистая вода». областной бюджет."
    )

    assert_equal "complete", result.status
    assert_equal "transfer", result.instruction["operation"]
    assert_equal "full_year_balance", result.instruction["amount_mode"]
    assert_nil result.instruction["amount_rub"]
    assert_equal %w[full_year_balance full_year_balance], result.operations.map { |operation| operation["amount_mode"] }
  end

  test "keeps clarified money amount when hierarchy numbers follow it" do
    result = ManualInstructionExtractor.new(
      organization: @organization,
      user: @user
    ).call(
      text: "перенести финансирование областного бюджета в размере 10 898,46 с 2027 на 2028. объект называется «Строительство водозаборного узла в поселке Мещерский Бор городского округа Шатура». Этот объект находится в мероприятии 02.01, основное мероприятие 02, подпрограмма номер 1 «Чистая вода»."
    )

    assert_equal "complete", result.status
    assert_equal "10898.46", result.instruction["amount_rub"]
  end

  test "asks for missing budget source instead of guessing" do
    result = ManualInstructionExtractor.new(
      organization: @organization,
      user: @user
    ).call(
      text: "Увеличь объект ВЗУ Черусти на 1 млн в 2027."
    )

    assert_equal "needs_clarification", result.status
    assert_includes result.missing_fields, "budget_source"
    assert_match(/источник/i, result.clarification_question)
  end

  test "employee manual flow asks hierarchy before financial operation details" do
    result = ManualInstructionExtractor.new(
      organization: @organization,
      user: @user
    ).call(
      text: "Увеличь объект ВЗУ Черусти на 1 млн в 2027.",
      context: { "interface_mode" => "employee" }
    )

    assert_equal "needs_clarification", result.status
    assert_includes result.missing_fields, "activity_ref"
    assert_includes result.missing_fields, "main_activity_ref"
    assert_includes result.missing_fields, "subprogram_ref"
    assert_match(/мероприятия/i, result.clarification_question)
  end
end
