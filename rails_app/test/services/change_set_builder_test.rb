require "test_helper"

class ChangeSetBuilderTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "changeset-builder@example.com")
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
    @node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
  end

  test "creates amount update change item from matched external funding delta" do
    document = excel_document!("ВЗУ Черусти", "1000004207.1000005123", "2026::LOCAL_BUDGET" => "150.00")
    session = analysis_session!(document)
    match_results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    change_set = ChangeSetBuilder.new(analysis_session: session, match_results: match_results).build!

    assert_equal "draft", change_set.status
    assert_equal session, change_set.analysis_session
    item = change_set.change_items.sole
    assert_equal @node, item.program_node
    assert_equal "amount_update", item.change_type
    assert_equal 2026, item.year
    assert_equal "LOCAL_BUDGET", item.source_type
    assert_equal BigDecimal("100.00"), item.old_amount_rub
    assert_equal BigDecimal("150.00"), item.new_amount_rub
    assert_equal BigDecimal("50.00"), item.delta_rub
    assert_equal "draft", item.status
    assert_not item.requires_user_confirmation
    assert_equal 61, item.source_reference["row_number"]
  end

  test "creates zeroing amount update when Excel target omits old DOCX funding key" do
    @node.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "200.00")
    document = excel_document!("ВЗУ Черусти", "1000004207.1000005123", "2027::LOCAL_BUDGET" => "180.00")
    session = analysis_session!(document)
    match_results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    change_set = ChangeSetBuilder.new(analysis_session: session, match_results: match_results).build!

    items = change_set.change_items.order(:year).to_a
    assert_equal 2, items.size
    zeroing = items.first
    assert_equal 2026, zeroing.year
    assert_equal "LOCAL_BUDGET", zeroing.source_type
    assert_equal BigDecimal("100.00"), zeroing.old_amount_rub
    assert_equal BigDecimal("0"), zeroing.new_amount_rub
    assert_equal BigDecimal("-100.00"), zeroing.delta_rub
    assert_equal "zeroing", zeroing.source_reference["amount_mode"]
    assert_equal true, zeroing.source_reference["target_model_absent_in_excel"]

    update = items.second
    assert_equal 2027, update.year
    assert_equal BigDecimal("200.00"), update.old_amount_rub
    assert_equal BigDecimal("180.00"), update.new_amount_rub
  end

  test "creates zeroing updates for DOCX objects fully absent from Excel target" do
    absent = @version.program_nodes.create!(
      node_type: "object",
      name: "ВЗУ Рошаль",
      normalized_name: "взу рошаль",
      display_number: "1.1.2"
    )
    absent.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "75.00")
    document = excel_document!("ВЗУ Черусти", "1000004207.1000005123", "2026::LOCAL_BUDGET" => "150.00")
    session = analysis_session!(document)
    match_results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    change_set = ChangeSetBuilder.new(analysis_session: session, match_results: match_results).build!

    zeroing = change_set.change_items.find_by!(program_node: absent)
    assert_equal "amount_update", zeroing.change_type
    assert_equal 2026, zeroing.year
    assert_equal BigDecimal("75.00"), zeroing.old_amount_rub
    assert_equal BigDecimal("0"), zeroing.new_amount_rub
    assert_equal BigDecimal("-75.00"), zeroing.delta_rub
    assert_equal "ABSENT_IN_EXCEL_TARGET", zeroing.source_reference["match_status"]
    assert_equal true, zeroing.source_reference["target_model_absent_in_excel"]
  end

  test "creates zeroing update when Excel target keeps object row with explicit zero funding" do
    document = excel_document!(
      "ВЗУ Черусти",
      "1000004207.1000005123",
      {},
      explicit_zero_target: true
    )
    session = analysis_session!(document)
    match_results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    change_set = ChangeSetBuilder.new(analysis_session: session, match_results: match_results).build!

    item = change_set.change_items.sole
    assert_equal 2026, item.year
    assert_equal "LOCAL_BUDGET", item.source_type
    assert_equal BigDecimal("100.00"), item.old_amount_rub
    assert_equal BigDecimal("0"), item.new_amount_rub
    assert_equal "zeroing", item.source_reference["amount_mode"]
    assert_equal true, item.source_reference["explicit_zero_target"]
  end

  test "ignores tiny Excel source reallocation when object total is unchanged within tolerance" do
    @node.funding_lines.destroy_all
    @node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "85407630.00")
    @node.funding_lines.create!(year: 2026, source_type: "REGIONAL_BUDGET", amount_rub: "219705510.00")
    document = excel_document!(
      "ВЗУ Черусти",
      "1000004207.1000005123",
      {
        "2026::LOCAL_BUDGET" => "85407510.00",
        "2026::REGIONAL_BUDGET" => "219705630.00"
      }
    )
    session = analysis_session!(document)
    match_results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    change_set = ChangeSetBuilder.new(analysis_session: session, match_results: match_results).build!

    assert_empty change_set.change_items
  end

  test "creates new object change item when source object is missing in program tree" do
    document = excel_document!("Новый объект", "NEW-1", "2026::LOCAL_BUDGET" => "250.00")
    session = analysis_session!(document)
    match_results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    change_set = ChangeSetBuilder.new(analysis_session: session, match_results: match_results).build!

    item = change_set.change_items.find_by!(change_type: "new_object")
    assert_nil item.program_node
    assert_equal "new_object", item.change_type
    assert_equal "draft", item.status
    assert_not item.requires_user_confirmation
    assert_equal "unresolved", item.agent_resolution_status
    assert_equal "Новый объект", item.new_value
    assert_equal BigDecimal("250.00"), item.new_amount_rub
    zeroing = change_set.change_items.find_by!(change_type: "amount_update")
    assert_equal @node, zeroing.program_node
    assert_equal BigDecimal("0"), zeroing.new_amount_rub
  end

  test "creates transfer pair as two autonomous amount updates" do
    @node.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "100000000.00")
    @node.funding_lines.create!(year: 2028, source_type: "LOCAL_BUDGET", amount_rub: "10000000.00")
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
            "confidence" => "0.96"
          }
        ]
      }
    )
    session = analysis_session!(document)
    match_results = ExternalSourceMatcher.new(analysis_session: session, source_document: document).match!

    change_set = ChangeSetBuilder.new(analysis_session: session, match_results: match_results).build!

    items = change_set.change_items.order(:year).to_a
    assert_equal 2, items.size
    assert_equal [2027, 2028], items.map(&:year)
    assert_equal [BigDecimal("-90000000.00"), BigDecimal("90000000.00")], items.map(&:delta_rub)
    assert_equal [BigDecimal("10000000.00"), BigDecimal("100000000.00")], items.map(&:new_amount_rub)
    assert items.none?(&:requires_user_confirmation)
    assert_equal ["unresolved", "unresolved"], items.map(&:agent_resolution_status)
    assert items.all? { |item| item.source_reference["transfer_pair"] }
  end

  private

  def analysis_session!(document)
    AnalysisSession.create!(
      organization: @organization,
      user: @user,
      program_version: @version,
      goal: "Создать проект изменений",
      selected_source_document_ids: [document.id]
    )
  end

  def excel_document!(object_name, object_code, funding = nil, explicit_zero_target: false, **funding_keywords)
    funding ||= funding_keywords
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
                "row_number" => 61,
                "row_type" => "OBJECT_LEAF_ROW",
                "parent_activity_code" => "01",
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
end
