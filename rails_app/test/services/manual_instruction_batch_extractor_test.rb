require "test_helper"

class ManualInstructionBatchExtractorTest < ActiveSupport::TestCase
  test "extracts existing amount updates and new activity from numbered manual instruction" do
    organization = create_isolated_user!(email: "manual-batch-extractor@example.com").organization
    text = <<~TEXT
      Excel не загружен. Выполни ручной режим. Все суммы ниже указаны в тыс. руб.

      1. В подпрограмме по информационной политике, основное мероприятие 01 «Информирование населения», мероприятие 01.03 «Телепередачи»: по источнику «Средства бюджета Городского округа Люберцы» установить 2026 год = 57310,79.

      2. В приложении по обеспечению деятельности органов местного самоуправления добавить в основное мероприятие 01 «Создание условий для реализации полномочий органов местного самоуправления» новое мероприятие 01.02 «Обеспечение деятельности муниципальных органов - комитет по молодежной политике», период 01.01.2026-31.12.2030, ответственный исполнитель: «Управление молодежной политики». По источнику «Средства бюджета Городского округа Люберцы» поставить: всего 16724,55; 2026 = 5574,85; 2027 = 5574,85; 2028 = 5574,85; 2029 = 0,00; 2030 = 0,00.
    TEXT

    result = ManualInstructionBatchExtractor.new(organization: organization).call(text: text)

    assert_equal "complete", result.status
    assert_equal 2, result.instructions.size
    assert_equal "amount_update", result.instructions.first["kind"]
    assert_equal "57310790.0", BigDecimal(result.instructions.first["amounts"].first["amount_rub"]).to_s("F")
    assert_equal "new_object", result.instructions.second["kind"]
    assert_equal "01.02", result.instructions.second["activity_code"]
    assert_equal "1.2", result.instructions.second["activity_display"]
    assert_equal "Создание условий для реализации полномочий органов местного самоуправления", result.instructions.second["main_activity_ref"]
    assert_equal "Управление молодежной политики", result.instructions.second["responsible"]
    assert_equal "01.01.2026-31.12.2030", result.instructions.second["execution_period"]
  end
end
