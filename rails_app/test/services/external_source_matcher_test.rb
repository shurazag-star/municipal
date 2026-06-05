require "test_helper"

class ExternalSourceMatcherTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "matcher@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие инженерной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @program.update!(current_version: @version)
    @node = @version.program_nodes.create!(
      node_type: "object",
      name: "ВЗУ Черусти",
      normalized_name: "взу черусти",
      display_number: "1.1.1"
    )
  end

  test "creates exact name match candidate and source excel row for grouped Excel object" do
    document = excel_document!(
      object_name: "ВЗУ Черусти",
      object_code: "1000004207.1000005123",
      row_number: 61,
      funding: { "2026::LOCAL_BUDGET" => "150.00" }
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    assert_equal 1, results.size
    candidate = document.match_candidates.sole
    assert_equal @node, candidate.program_node
    assert_equal "MATCH_EXACT_NAME", candidate.match_status
    assert_equal BigDecimal("1.0"), candidate.confidence
    assert_not candidate.requires_user_confirmation
    assert_equal 61, candidate.excel_row.row_number
    assert_equal "ВЗУ Черусти", candidate.excel_row.normalized_values["object_name"]
    assert_equal "01", results.first.source_reference["parent_activity_code"]
  end

  test "keeps explicit zero Excel target row for matched object" do
    @node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
    document = excel_document!(
      object_name: "ВЗУ Черусти",
      object_code: "1000004207.1000005123",
      row_number: 61,
      funding: {},
      explicit_zero_target: true
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    assert_equal 1, results.size
    assert_equal @node, results.first.program_node
    assert_empty results.first.funding_entries
    assert_equal true, results.first.source_reference["explicit_zero_target"]
  end

  test "does not use residual group row number as object name" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "object_groups" => [
          {
            "group_key" => "UNASSIGNED_RESIDUAL::101020100000000::14",
            "status" => "UNASSIGNED_RESIDUAL",
            "funding" => { "2026::LOCAL_BUDGET" => "250.00" },
            "rows" => [
              {
                "row_number" => 14,
                "row_type" => "UNASSIGNED_RESIDUAL",
                "parent_activity_code" => "101020100000000",
                "object_code" => "0000000000.0000000000",
                "object_name" => nil,
                "funding" => { "2026::LOCAL_BUDGET" => "250.00" },
                "raw_values" => { "Наименование" => "Неуказанное направление" }
              }
            ]
          }
        ]
      }
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    assert_equal "Неуказанное направление", results.first.external_group["object_name"]
    assert_equal "Неуказанное направление", document.excel_rows.sole.normalized_values["object_name"]
    assert_equal "101020100000000", results.first.source_reference["parent_activity_code"]
  end

  test "matches activity aggregate row with municipal program prefix code" do
    subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 1",
      display_number: "1"
    )
    activity = @version.program_nodes.create!(
      parent: subprogram,
      node_type: "object",
      code: "01.05",
      display_number: "1.4",
      name: "Мероприятие 01.05 Информирование населения об основных событиях социально-экономического развития, общественно-политической жизни, освещение деятельности в печатных СМИ",
      normalized_name: "мероприятие 0105 информирование населения об основных событиях социально экономического развития общественно политической жизни освещение деятельности в печатных сми"
    )
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "object_groups" => [
          {
            "group_key" => "131010500000000::131010500000000::информирование населения",
            "status" => "ACTIVITY_AGGREGATE",
            "parent_activity_code" => "131010500000000",
            "object_code" => "131010500000000",
            "object_name" => "Информирование населения об основных событиях социально-экономического развития, общественно-политической жизни, освещение деятельности в печатных СМИ",
            "funding" => { "2026::LOCAL_BUDGET" => "2000000.00" },
            "rows" => [
              {
                "row_number" => 13,
                "row_type" => "ACTIVITY_AGGREGATE_ROW",
                "parent_activity_code" => "131010500000000",
                "object_code" => "",
                "object_name" => "Информирование населения об основных событиях социально-экономического развития, общественно-политической жизни, освещение деятельности в печатных СМИ",
                "funding" => { "2026::LOCAL_BUDGET" => "2000000.00" },
                "raw_values" => { "Наименование" => "Информирование населения об основных событиях социально-экономического развития, общественно-политической жизни, освещение деятельности в печатных СМИ" }
              }
            ]
          }
        ]
      }
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document, semantic_agent: nil).match!

    assert_equal activity, results.first.program_node
    assert_equal "ACTIVITY_AGGREGATE", results.first.source_reference["group_status"]
    assert_equal 13, results.first.candidate.excel_row.row_number
  end

  test "matches activity aggregate row when municipal code subprogram is shifted from finance table index" do
    activity = @version.program_nodes.create!(
      parent: @program.current_version.program_nodes.find_by(name: @program.name),
      node_type: "object",
      code: "02.01",
      display_number: "1.1",
      name: "Мероприятие 02.01.Реализация на территориях муниципальных образований проектов граждан, сформированных в рамках практик инициативного бюджетирования",
      normalized_name: "мероприятие 02 01 реализация на территориях муниципальных образований проектов граждан сформированных в рамках практик инициативного бюджетирования",
      metadata: { "finance_table_index" => 2 }
    )
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "object_groups" => [
          {
            "group_key" => "133020100000000::133020100000000::реализация на территориях муниципальных образований проектов граждан сформированных в рамках практик инициативного бюджетирования",
            "status" => "ACTIVITY_AGGREGATE",
            "parent_activity_code" => "133020100000000",
            "object_code" => "133020100000000",
            "object_name" => "Реализация на территориях муниципальных образований проектов граждан, сформированных в рамках практик инициативного бюджетирования",
            "funding" => { "2026::REGIONAL_BUDGET" => "21440240.00" },
            "rows" => [
              {
                "row_number" => 45,
                "row_type" => "ACTIVITY_AGGREGATE_ROW",
                "parent_activity_code" => "133020100000000",
                "object_name" => "Реализация на территориях муниципальных образований проектов граждан, сформированных в рамках практик инициативного бюджетирования",
                "funding" => { "2026::REGIONAL_BUDGET" => "21440240.00" }
              }
            ]
          }
        ]
      }
    )
    session = analysis_session!(document)

    result = ExternalSourceMatcher.new(analysis_session: session, source_document: document, semantic_agent: nil).match!.first

    assert_equal activity, result.program_node
    assert_equal "MATCH_FUZZY_CONFIDENT", result.match_status
  end

  test "matches residual Excel row to existing parent activity when amount is already present" do
    subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 4",
      display_number: "4"
    )
    activity = @version.program_nodes.create!(
      parent: subprogram,
      node_type: "activity",
      code: "02.02",
      display_number: "2.2",
      name: "Мероприятие 02.02. Выполнение работ по установке автоматизированных систем контроля за газовой безопасностью"
    )
    activity.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "1000000.00")
    other_activity = @version.program_nodes.create!(
      parent: subprogram,
      node_type: "activity",
      code: "02.02",
      display_number: "2.2",
      name: "Мероприятие 02.02 другой подпрограммы"
    )
    other_activity.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "3568700.00")
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "object_groups" => [
          {
            "group_key" => "UNASSIGNED_RESIDUAL::105020200000000::166",
            "status" => "UNASSIGNED_RESIDUAL",
            "funding" => { "2027::LOCAL_BUDGET" => "1000000.00" },
            "rows" => [
              {
                "row_number" => 166,
                "row_type" => "UNASSIGNED_RESIDUAL",
                "parent_activity_code" => "105020200000000",
                "object_code" => "0000000000.0000000000",
                "object_name" => "Выполнение работ по установке автоматизированных систем контроля за газовой безопасностью",
                "funding" => { "2027::LOCAL_BUDGET" => "1000000.00" },
                "raw_values" => { "Наименование" => "Неуказанное направление" }
              }
            ]
          }
        ]
      }
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    assert_equal activity, results.first.program_node
    assert_equal "MATCH_RESIDUAL_PARENT_TOTAL", results.first.match_status
  end

  test "does not match residual parent total when Excel only covers part of parent funding" do
    subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 3",
      display_number: "3"
    )
    activity = @version.program_nodes.create!(
      parent: subprogram,
      node_type: "activity",
      code: "01.31",
      display_number: "1.8",
      name: "Мероприятие 01.31"
    )
    activity.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "23474030.00")
    activity.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "1106000.00")
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "object_groups" => [
          {
            "group_key" => "UNASSIGNED_RESIDUAL::103013100000000::61",
            "status" => "UNASSIGNED_RESIDUAL",
            "funding" => { "2027::LOCAL_BUDGET" => "1106000.00" },
            "rows" => [
              {
                "row_number" => 61,
                "row_type" => "UNASSIGNED_RESIDUAL",
                "parent_activity_code" => "103013100000000",
                "object_code" => "0000000000.0000000000",
                "object_name" => "Строительство и реконструкция объектов теплоснабжения",
                "funding" => { "2027::LOCAL_BUDGET" => "1106000.00" },
                "raw_values" => { "Наименование" => "Неуказанное направление" }
              }
            ]
          }
        ]
      }
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    assert_not_equal "MATCH_RESIDUAL_PARENT_TOTAL", results.first.match_status
  end

  test "does not map residual Excel row to nearest semantic parent total row" do
    activity = @version.program_nodes.create!(
      node_type: "activity",
      name: "Организация в границах муниципального образования электро-, тепло-, газо- и водоснабжения населения, водоотведения, снабжения населения топливом",
      normalized_name: "организация в границах муниципального образования электро тепло газо и водоснабжения населения водоотведения снабжения населения топливом",
      display_number: "1.3",
      code: "01.03"
    )
    @version.program_nodes.create!(
      parent: activity,
      node_type: "object",
      name: "Итого по подпрограмме",
      normalized_name: "итого по подпрограмме",
      display_number: "Итого по подпрограмме",
      code: "Итого по подпрограмме"
    )
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "rows" => [
          {
            "row_number" => 169,
            "row_type" => "UNKNOWN_ROW",
            "raw_values" => {
              "Наименование" => activity.name,
              "Классификация Код цел. программы.  Код мероприятия" => "1060100190"
            }
          },
          {
            "row_number" => 170,
            "row_type" => "UNASSIGNED_RESIDUAL_ROW",
            "raw_values" => {
              "Наименование" => "Неуказанное направление",
              "Классификация Код цел. программы.  Код мероприятия" => "1060100190"
            }
          }
        ],
        "object_groups" => [
          {
            "group_key" => "UNASSIGNED_RESIDUAL::106010200000000::170",
            "status" => "UNASSIGNED_RESIDUAL",
            "funding" => { "2026::LOCAL_BUDGET" => "5311823.36" },
            "rows" => [
              {
                "row_number" => 170,
                "row_type" => "UNASSIGNED_RESIDUAL_ROW",
                "parent_activity_code" => "106010200000000",
                "object_code" => "0000000000.0000000000",
                "object_name" => nil,
                "funding" => { "2026::LOCAL_BUDGET" => "5311823.36" },
                "raw_values" => {
                  "Наименование" => "Неуказанное направление",
                  "Классификация Код цел. программы.  Код мероприятия" => "1060100190"
                }
              }
            ]
          }
        ]
      }
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    assert_nil results.first.program_node
    assert_equal "UNASSIGNED_RESIDUAL", document.match_candidates.sole.match_status
    assert_equal activity.name, results.first.source_reference["residual_parent_name"]
    assert_equal 169, results.first.source_reference["residual_parent_row_number"]
    assert document.match_candidates.sole.requires_user_confirmation
  end

  test "does not map residual Excel row to result indicator nodes" do
    result_name = "Приобретено коммунальной техники для содержания объектов инженерной инфраструктуры"
    @version.program_nodes.create!(
      node_type: "result",
      name: result_name,
      normalized_name: result_name.downcase,
      display_number: "1.1"
    )
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "rows" => [
          {
            "row_number" => 13,
            "row_type" => "UNKNOWN_ROW",
            "raw_values" => {
              "Наименование" => result_name,
              "Классификация Код цел. программы.  Код мероприятия" => "1010270330"
            }
          },
          {
            "row_number" => 14,
            "row_type" => "UNASSIGNED_RESIDUAL_ROW",
            "raw_values" => {
              "Наименование" => "Неуказанное направление",
              "Классификация Код цел. программы.  Код мероприятия" => "1010270330"
            }
          }
        ],
        "object_groups" => [
          {
            "group_key" => "UNASSIGNED_RESIDUAL::101021300000000::14",
            "status" => "UNASSIGNED_RESIDUAL",
            "funding" => { "2026::LOCAL_BUDGET" => "7388096.53" },
            "rows" => [
              {
                "row_number" => 14,
                "row_type" => "UNASSIGNED_RESIDUAL_ROW",
                "parent_activity_code" => "101021300000000",
                "object_code" => "0000000000.0000000000",
                "object_name" => nil,
                "funding" => { "2026::LOCAL_BUDGET" => "7388096.53" },
                "raw_values" => {
                  "Наименование" => "Неуказанное направление",
                  "Классификация Код цел. программы.  Код мероприятия" => "1010270330"
                }
              }
            ]
          }
        ]
      }
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    assert_nil results.first.program_node
    assert_equal "UNASSIGNED_RESIDUAL", document.match_candidates.sole.match_status
    assert document.match_candidates.sole.requires_user_confirmation
  end

  test "marks unmatched Excel object as requiring user confirmation" do
    document = excel_document!(
      object_name: "Новый объект водоснабжения",
      object_code: "NEW-1",
      row_number: 77,
      funding: { "2026::LOCAL_BUDGET" => "250.00" }
    )
    session = analysis_session!(document)

    ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    candidate = document.match_candidates.sole
    assert_nil candidate.program_node
    assert_equal "MISSING_IN_DOCX", candidate.match_status
    assert candidate.requires_user_confirmation
    assert_equal "needs_confirmation", candidate.user_decision
  end

  test "does not match Excel object to same name under different parent activity" do
    subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 3",
      display_number: "3"
    )
    main_activity = @version.program_nodes.create!(
      parent: subprogram,
      node_type: "main_activity",
      name: "Основное мероприятие 01",
      display_number: "1",
      code: "01"
    )
    matching_activity = @version.program_nodes.create!(
      parent: main_activity,
      node_type: "activity",
      name: "Мероприятие 01.07",
      display_number: "1.3",
      code: "01.07"
    )
    @version.program_nodes.create!(
      parent: matching_activity,
      node_type: "object",
      name: "Строительство БМК мощностью 10 МВт",
      normalized_name: "строительство бмк мощностью 10 мвт",
      display_number: "1.3.2"
    )
    @version.program_nodes.create!(
      parent: main_activity,
      node_type: "activity",
      name: "Мероприятие 01.29",
      display_number: "1.7",
      code: "01.29"
    )
    document = excel_document!(
      object_name: "Строительство БМК мощностью 10 МВт",
      object_code: "1000004047.1000004922",
      row_number: 59,
      parent_activity_code: "103012900000000",
      funding: { "2026::LOCAL_BUDGET" => "11245920.00" }
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    assert_nil results.first.program_node
    assert_equal "MISSING_IN_DOCX", document.match_candidates.sole.match_status
    assert document.match_candidates.sole.requires_user_confirmation
  end

  test "matches shortened Excel object name to existing object under the same parent activity" do
    subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 1",
      display_number: "1"
    )
    main_activity = @version.program_nodes.create!(
      parent: subprogram,
      node_type: "main_activity",
      name: "Основное мероприятие 02",
      display_number: "2",
      code: "02"
    )
    activity = @version.program_nodes.create!(
      parent: main_activity,
      node_type: "activity",
      name: "Мероприятие 02.01",
      display_number: "2.1",
      code: "02.01"
    )
    object = @version.program_nodes.create!(
      parent: activity,
      node_type: "object",
      name: "Реконструкция водозаборного узла с бурением новой скважины и станцией очистки воды по адресу: г. Шатура, ул. Чехова, 79 производительностью 1560 м3/сут. (в т.ч. ПИР)",
      normalized_name: "реконструкция водозаборного узла с бурением новой скважины и станцией очистки воды по адресу г шатура ул чехова 79 производительностью 1560 м3 сут в т ч пир",
      display_number: "2.1.3"
    )
    document = excel_document!(
      object_name: "Реконструкция водозаборных узлов по адресу: г. Шатура, ул. Чехова, 79",
      object_code: "1000004207.1000005123",
      row_number: 26,
      parent_activity_code: "101020100000000",
      funding: { "2027::REGIONAL_BUDGET" => "1.00" }
    )
    session = analysis_session!(document)

    result = ExternalSourceMatcher.new(
      analysis_session: session,
      source_document: document,
      semantic_agent: nil
    ).match!.first

    assert_equal object, result.program_node
    assert_equal "MATCH_FUZZY_CONFIDENT", document.match_candidates.sole.match_status
    assert_not document.match_candidates.sole.requires_user_confirmation
  end

  test "matches typo in Excel object name to existing object under the same parent activity" do
    subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 3",
      display_number: "3"
    )
    main_activity = @version.program_nodes.create!(
      parent: subprogram,
      node_type: "main_activity",
      name: "Основное мероприятие 02",
      display_number: "2",
      code: "02"
    )
    activity = @version.program_nodes.create!(
      parent: main_activity,
      node_type: "activity",
      name: "Мероприятие 02.01",
      display_number: "2.1",
      code: "02.01"
    )
    object = @version.program_nodes.create!(
      parent: activity,
      node_type: "object",
      name: "Наружные сети водоснабжения, водоотведения и теплоснабжения г.о. Шатура",
      normalized_name: "наружные сети водоснабжения водоотведения и теплоснабжения г о шатура",
      display_number: "2.1.1"
    )
    document = excel_document!(
      object_name: "Наружные сети водоснабжения, водоотведеиня и теплоснабжения г.о. Шатура",
      object_code: "1000004207.1000005123",
      row_number: 122,
      parent_activity_code: "103020100000000",
      funding: { "2026::LOCAL_BUDGET" => "1.00" }
    )
    session = analysis_session!(document)

    result = ExternalSourceMatcher.new(
      analysis_session: session,
      source_document: document,
      semantic_agent: nil
    ).match!.first

    assert_equal object, result.program_node
    assert_equal "MATCH_FUZZY_CONFIDENT", document.match_candidates.sole.match_status
  end

  test "uses external parent activity code instead of visual activity display number" do
    subprogram = @version.program_nodes.create!(
      node_type: "subprogram",
      name: "Подпрограмма 3",
      display_number: "3"
    )
    main_activity = @version.program_nodes.create!(
      parent: subprogram,
      node_type: "main_activity",
      name: "Основное мероприятие 01",
      display_number: "1",
      code: "01"
    )
    expected_activity = @version.program_nodes.create!(
      parent: main_activity,
      node_type: "activity",
      name: "Мероприятие 01.07",
      display_number: "1.3",
      code: "01.07"
    )
    expected_object = @version.program_nodes.create!(
      parent: expected_activity,
      node_type: "object",
      name: "Строительство БМК мощностью 15 МВт по адресу: Московская область, г.о. Шатура, п. Шатурторф (в т.ч. ПИР)",
      normalized_name: "строительство бмк мощностью 15 мвт по адресу московская область г о шатура п шатурторф в т ч пир",
      display_number: "1.3.6"
    )
    wrong_activity = @version.program_nodes.create!(
      parent: main_activity,
      node_type: "activity",
      name: "Мероприятие 01.29",
      display_number: "1.7",
      code: "01.29"
    )
    @version.program_nodes.create!(
      parent: wrong_activity,
      node_type: "object",
      name: expected_object.name,
      normalized_name: expected_object.normalized_name,
      display_number: "1.7.1"
    )
    document = excel_document!(
      object_name: expected_object.name,
      object_code: "1000004207.1000005123",
      row_number: 77,
      parent_activity_code: "103010700000000",
      funding: { "2026::LOCAL_BUDGET" => "1.00" }
    )
    session = analysis_session!(document)

    result = ExternalSourceMatcher.new(
      analysis_session: session,
      source_document: document,
      semantic_agent: nil
    ).match!.first

    assert_equal expected_object, result.program_node
    assert_equal "MATCH_EXACT_NAME", document.match_candidates.sole.match_status
  end

  test "does not call semantic agent for coded Excel target objects with parent activity" do
    document = excel_document!(
      object_name: "Строительство блочно-модульной котельной",
      object_code: "4036470831.4036471081",
      row_number: 55,
      funding: { "2026::LOCAL_BUDGET" => "1757008.12" }
    )
    session = analysis_session!(document)

    result = ExternalSourceMatcher.new(
      analysis_session: session,
      source_document: document,
      semantic_agent: RaisingSemanticAgent.new
    ).match!.first

    assert_nil result.program_node
    assert_equal "MISSING_IN_DOCX", result.match_status
    assert result.requires_user_confirmation
  end

  test "does not call semantic agent for coded activity aggregate rows" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "object_groups" => [
          {
            "group_key" => "136010200000000::136010200000000::обеспечение деятельности муниципальных органов",
            "status" => "ACTIVITY_AGGREGATE",
            "parent_activity_code" => "136010200000000",
            "object_code" => "136010200000000",
            "object_name" => "Обеспечение деятельности муниципальных органов - комитет по молодежной политике",
            "funding" => { "2026::LOCAL_BUDGET" => "5574845.99" },
            "rows" => [
              {
                "row_number" => 67,
                "row_type" => "ACTIVITY_AGGREGATE_ROW",
                "parent_activity_code" => "136010200000000",
                "object_code" => "136010200000000",
                "object_name" => "Обеспечение деятельности муниципальных органов - комитет по молодежной политике",
                "funding" => { "2026::LOCAL_BUDGET" => "5574845.99" }
              }
            ]
          }
        ]
      }
    )
    session = analysis_session!(document)

    result = ExternalSourceMatcher.new(
      analysis_session: session,
      source_document: document,
      semantic_agent: RaisingSemanticAgent.new
    ).match!.first

    assert_nil result.program_node
    assert_equal "MISSING_IN_DOCX", result.match_status
    assert result.requires_user_confirmation
  end

  test "uses semantic match agent after deterministic matching is insufficient" do
    fuzzy_node = @version.program_nodes.create!(
      node_type: "object",
      name: "Капитальный ремонт водозаборного узла Черусти",
      normalized_name: "капитальный ремонт водозаборного узла черусти",
      display_number: "1.2"
    )
    document = excel_document!(
      object_name: "Реконструкция ВЗУ в поселке Черусти",
      object_code: "",
      row_number: 88,
      funding: { "2026::LOCAL_BUDGET" => "250.00" }
    )
    session = analysis_session!(document)
    semantic_agent = FakeSemanticAgent.new(node: fuzzy_node)

    result = ExternalSourceMatcher.new(
      analysis_session: session,
      source_document: document,
      semantic_agent: semantic_agent
    ).match!.first

    assert_equal fuzzy_node, result.program_node
    assert_equal "MATCH_SEMANTIC_AGENT", result.match_status
    assert_not result.requires_user_confirmation
    assert_equal "MATCH_SEMANTIC_AGENT", document.match_candidates.sole.match_status
  end

  test "keeps ambiguous short PDF object names unresolved instead of choosing first fuzzy match" do
    @version.program_nodes.create!(
      node_type: "object",
      name: "ВЗУ Туголесский Бор",
      normalized_name: "взу туголесский бор",
      display_number: "1.1.2"
    )
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Краткое PDF-основание.pdf",
      status: "parsed",
      parsed_payload: {
        "changes" => [
          {
            "object_name" => "ВЗУ",
            "year" => 2027,
            "source_type" => "LOCAL_BUDGET",
            "amount_mode" => "absolute",
            "amount_rub" => "1000000.00",
            "confidence" => "0.95",
            "page_number" => 2
          }
        ]
      }
    )
    session = analysis_session!(document)

    result = ExternalSourceMatcher.new(
      analysis_session: session,
      source_document: document,
      semantic_agent: nil
    ).match!.first

    assert_nil result.program_node
    assert_equal "NEEDS_CONFIRMATION", document.match_candidates.sole.match_status
    assert document.match_candidates.sole.requires_user_confirmation
  end

  test "matches structured PDF agreement changes and keeps page reference in result" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение.pdf",
      status: "parsed",
      parsed_payload: {
        "changes" => [
          {
            "object_name" => "ВЗУ Черусти",
            "year" => 2026,
            "source_type" => "LOCAL_BUDGET",
            "amount_rub" => "175.00",
            "page_number" => 4,
            "evidence_text" => "Сумма по объекту ВЗУ Черусти на 2026 год увеличена."
          }
        ]
      }
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    assert_equal "MATCH_EXACT_NAME", document.match_candidates.sole.match_status
    assert_equal 4, results.first.source_reference["page_number"]
    assert_equal "Сумма по объекту ВЗУ Черусти на 2026 год увеличена.", results.first.source_reference["evidence_text"]
    assert_equal "pdf_agreement", results.first.source_reference["document_type"]
  end

  test "matches PDF appendix table by event name and keeps only program period years" do
    event_node = @version.program_nodes.create!(
      node_type: "object",
      name: "Капитальный ремонт сетей водоснабжения, водоотведения за счет средств местного бюджета",
      normalized_name: "капитальный ремонт сетей водоснабжения водоотведения за счет средств местного бюджета",
      display_number: "1.4.1"
    )
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение.pdf",
      status: "parsed",
      parsed_payload: {
        "changes" => [
          {
            "object_name" => "Капитальный ремонт сетей водоснабжения, водоотведения: Капитальный ремонт сетей ВС, г.о. Шатура (1 этап)",
            "event_name" => "Капитальный ремонт сетей водоснабжения, водоотведения",
            "year" => 2025,
            "source_type" => "REGIONAL_BUDGET",
            "amount_mode" => "absolute",
            "amount_rub" => "1.00",
            "confidence" => "0.95",
            "page_number" => 6
          },
          {
            "object_name" => "Капитальный ремонт сетей водоснабжения, водоотведения: Капитальный ремонт сетей ВС, г.о. Шатура (1 этап)",
            "event_name" => "Капитальный ремонт сетей водоснабжения, водоотведения",
            "year" => 2026,
            "source_type" => "REGIONAL_BUDGET",
            "amount_mode" => "absolute",
            "amount_rub" => "100000000.00",
            "confidence" => "0.95",
            "page_number" => 6
          },
          {
            "object_name" => "Капитальный ремонт сетей водоснабжения, водоотведения: Капитальный ремонт сетей ВС, г.о. Шатура (1 этап)",
            "event_name" => "Капитальный ремонт сетей водоснабжения, водоотведения",
            "year" => 2027,
            "source_type" => "LOCAL_BUDGET",
            "amount_mode" => "absolute",
            "amount_rub" => "4038310.00",
            "confidence" => "0.95",
            "page_number" => 6
          }
        ]
      }
    )
    session = analysis_session!(document)

    result = ExternalSourceMatcher.new(
      analysis_session: session,
      source_document: document,
      semantic_agent: nil
    ).match!.first

    assert_equal event_node, result.program_node
    assert_equal "MATCH_PDF_EVENT_NAME", document.match_candidates.sole.match_status
    assert_equal [2026, 2027], result.funding_entries.map { |entry| entry["year"] }.sort
    assert_equal BigDecimal("100000000.00"), result.funding_entries.detect { |entry| entry["source_type"] == "REGIONAL_BUDGET" }["amount_rub"]
    assert_equal 6, result.source_reference["page_number"]
  end

  test "matches PDF appendix row to specific object before shared event fallback" do
    @version.program_nodes.create!(
      node_type: "object",
      name: "Строительство (реконструкция), канализационных коллекторов, канализационных насосных станций муниципальной собственности",
      normalized_name: "строительство реконструкция канализационных коллекторов канализационных насосных станций муниципальной собственности",
      display_number: "2.1.7"
    )
    specific_node = @version.program_nodes.create!(
      node_type: "object",
      name: "Реконструкция КНС № 1 ул. 3-го Интернационала м.о. Шатура (в т.ч. ПИР)",
      normalized_name: "реконструкция кнс 1 ул 3 го интернационала м о шатура в т ч пир",
      display_number: "2.1.6"
    )
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение КНС.pdf",
      status: "parsed",
      parsed_payload: {
        "changes" => [
          {
            "object_name" => specific_node.name,
            "event_name" => "Строительство (реконструкция) канализационных коллекторов, канализационных насосных станций муниципальной собственности",
            "year" => 2026,
            "source_type" => "REGIONAL_BUDGET",
            "amount_mode" => "absolute",
            "amount_rub" => "12506660.00",
            "confidence" => "0.95",
            "page_number" => 9,
            "table_type" => "appendix_budget_table"
          }
        ]
      }
    )
    session = analysis_session!(document)

    result = ExternalSourceMatcher.new(
      analysis_session: session,
      source_document: document,
      semantic_agent: nil
    ).match!.first

    assert_equal specific_node, result.program_node
    assert_equal "MATCH_EXACT_NAME", document.match_candidates.sole.match_status
  end

  test "keeps low-confidence OCR PDF changes unresolved for autonomous clarification" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Скан.pdf",
      status: "parsed",
      parsed_payload: {
        "text_extraction_method" => "ocr",
        "warnings" => ["OCR применен"],
        "changes" => [
          {
            "object_name" => "ВЗУ Черусти",
            "year" => 2026,
            "source_type" => "LOCAL_BUDGET",
            "amount_mode" => "absolute",
            "amount_rub" => "175.00",
            "confidence" => 0.45,
            "page_number" => 4,
            "evidence_text" => "Сумма распознана по скану."
          }
        ]
      }
    )
    session = analysis_session!(document)

    result = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!.first

    assert_equal "ocr", result.source_reference["text_extraction_method"]
    assert result.funding_entries.first["ocr_applied"]
    change_set = ChangeSetBuilder.new(analysis_session: session, match_results: [result]).build!
    item = change_set.change_items.sole
    assert_not item.requires_user_confirmation
    assert_equal "draft", item.status
    assert_equal "unresolved", item.agent_resolution_status
    assert item.source_reference["ocr_applied"]
  end

  test "expands PDF transfer changes into decrease and increase funding entries" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_agreement",
      filename: "Соглашение о переносе.pdf",
      status: "parsed",
      parsed_payload: {
        "changes" => [
          {
            "object_name" => "ВЗУ Черусти",
            "source_type" => "LOCAL_BUDGET",
            "amount_mode" => "transfer",
            "amount_rub" => "90000000.00",
            "from_year" => 2027,
            "to_year" => 2028,
            "page_number" => 3,
            "evidence_text" => "Перенести 90 млн рублей с 2027 года на 2028 год."
          }
        ]
      }
    )
    session = analysis_session!(document)

    results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    entries = results.first.funding_entries.sort_by { |entry| entry["year"] }
    assert_equal [2027, 2028], entries.map { |entry| entry["year"] }
    assert_equal ["delta_minus", "delta_plus"], entries.map { |entry| entry["amount_mode"] }
    assert_equal BigDecimal("-90000000.00"), BigDecimal(entries.first["delta_rub"].to_s)
    assert_equal BigDecimal("90000000.00"), BigDecimal(entries.second["delta_rub"].to_s)
    assert entries.all? { |entry| entry["transfer_pair"] }
  end

  private

  def analysis_session!(document)
    AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      goal: "Проверить изменения",
      selected_source_document_ids: [document.id]
    )
  end

  def excel_document!(object_name:, object_code:, row_number:, funding:, explicit_zero_target: false, parent_activity_code: "01")
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "object_groups" => [
          {
            "group_key" => "01::#{object_code}::#{object_name}",
            "status" => "GROUPED_OBJECT",
            "funding" => funding,
            "explicit_zero_target" => explicit_zero_target,
            "rows" => [
              {
                "row_number" => row_number,
                "row_type" => "OBJECT_LEAF_ROW",
                "parent_activity_code" => parent_activity_code,
                "object_code" => object_code,
                "object_name" => object_name,
                "funding" => funding,
                "explicit_zero_target" => explicit_zero_target,
                "raw_values" => { "Наименование объекта" => object_name }
              }
            ]
          }
        ]
      }
    )
  end

  class FakeSemanticAgent
    def initialize(node:)
      @node = node
    end

    def resolve(group:, candidates:)
      {
        status: "matched",
        node: @node,
        confidence: BigDecimal("0.82"),
        reason: "Семантическое сопоставление по краткому списку кандидатов"
      }
    end
  end

  class RaisingSemanticAgent
    def resolve(group:, candidates:)
      raise "semantic agent should not be called for coded Excel target rows"
    end
  end
end
