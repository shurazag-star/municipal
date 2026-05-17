require "test_helper"

class PostExportDocxValidatorTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "post-export-validator@example.com")
    @program = MunicipalProgram.create!(
      organization: @user.organization,
      name: "Развитие инженерной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2027
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 2, status: "changed")
    @root = @version.program_nodes.create!(node_type: "program", name: "Программа")
    @root.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "150000.00")
    @root.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "200000.00")
    @document = SourceDocument.create!(
      organization: @user.organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "generated.docx",
      status: "parsed",
      parsed_payload: {}
    )
    @document.file_attachment.attach(
      io: File.open(Rails.root.join("test/fixtures/files/change_set_source.docx")),
      filename: "generated.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
  end

  test "returns valid when generated docx passport matches target model" do
    result = PostExportDocxValidator.new(
      program_version: @version,
      generated_docx_attachment: @document.file_attachment,
      parser_client: FakeParserClient.new("passport_totals_by_year" => { "2026" => "150000.00", "2027" => "200000.00" }),
      visual_renderer: FakeVisualRenderer.new("valid")
    ).validate

    assert_equal "valid", result["status"]
    assert_empty result["errors"]
    assert_equal "0.00", result.dig("passport", "2026", "delta_rub")
    assert_equal "valid", result.dig("visual_render", "status")
  end

  test "returns invalid with passport diffs when generated docx keeps old totals" do
    result = PostExportDocxValidator.new(
      program_version: @version,
      generated_docx_attachment: @document.file_attachment,
      parser_client: FakeParserClient.new("passport_totals_by_year" => { "2026" => "100000.00", "2027" => "200000.00" }),
      visual_renderer: FakeVisualRenderer.new("valid")
    ).validate

    assert_equal "invalid", result["status"]
    assert_equal "passport_total_mismatch", result["errors"].first["code"]
    assert_equal "2026", result["errors"].first["year"]
    assert_equal "-50000.00", result.dig("passport", "2026", "delta_rub")
  end

  test "marks export invalid when visual render fails" do
    result = PostExportDocxValidator.new(
      program_version: @version,
      generated_docx_attachment: @document.file_attachment,
      parser_client: FakeParserClient.new("passport_totals_by_year" => { "2026" => "150000.00", "2027" => "200000.00" }),
      visual_renderer: FakeVisualRenderer.new("invalid")
    ).validate

    assert_equal "invalid", result["status"]
    assert_equal "visual_render_failed", result["errors"].last["code"]
  end

  test "fails when generated docx matches internal model but not external Excel target" do
    @root.funding_lines.find_by!(year: 2026, source_type: "LOCAL_BUDGET").update!(amount_rub: "500000.00")
    excel_target = SourceDocument.create!(
      organization: @user.organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "final_totals" => { "2026" => "150000.00", "2027" => "200000.00" },
        "object_groups" => [
          {
            "group_key" => "01::OBJ::Объект",
            "status" => "GROUPED_OBJECT",
            "funding" => { "2026::LOCAL_BUDGET" => "150000.00", "2027::LOCAL_BUDGET" => "200000.00" }
          }
        ]
      }
    )

    result = PostExportDocxValidator.new(
      program_version: @version,
      generated_docx_attachment: @document.file_attachment,
      external_target_document: excel_target,
      parser_client: FakeParserClient.new(
        "passport_totals_by_year" => { "2026" => "500000.00", "2027" => "200000.00" },
        "passport_amounts" => { "2026::LOCAL_BUDGET" => "500000.00", "2027::LOCAL_BUDGET" => "200000.00" },
        "passport_source_total_column_amounts" => { "LOCAL_BUDGET" => "700000.00" },
        "passport_grand_total_column_amount" => "700000.00"
      ),
      visual_renderer: FakeVisualRenderer.new("valid")
    ).validate

    assert_equal "invalid", result["status"]
    assert_includes result["errors"].map { |error| error["code"] }, "external_passport_total_mismatch"
    assert_equal "xlsx_finance", result.dig("external_target", "document_type")
  end

  test "returns invalid when object funding rows do not match target version" do
    object = @version.program_nodes.create!(
      node_type: "object",
      parent: @root,
      source_table_index: 5,
      source_row_index: 35,
      display_number: "2.1.3",
      name: "Реконструкция КНС № 2 на ул. 1-ая Первомайская м.о. Шатура"
    )
    object.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "17898180.00")

    result = PostExportDocxValidator.new(
      program_version: @version,
      generated_docx_attachment: @document.file_attachment,
      parser_client: FakeParserClient.new(
        "passport_totals_by_year" => { "2026" => "150000.00", "2027" => "200000.00" },
        "nodes" => [
          {
            "stable_key" => "object:5:35:2-1-3",
            "node_type" => "object",
            "source_table_index" => 5,
            "display_number" => "2.1.3",
            "name" => "Реконструкция КНС № 2 на ул. 1-ая Первомайская м.о. Шатура"
          }
        ],
        "funding_lines" => [
          {
            "node_stable_key" => "object:5:35:2-1-3",
            "year" => 2027,
            "source_type" => "LOCAL_BUDGET",
            "amount_rub" => "0.00"
          }
        ]
      ),
      visual_renderer: FakeVisualRenderer.new("valid")
    ).validate

    assert_equal "invalid", result["status"]
    error = result["errors"].detect { |item| item["code"] == "object_funding_mismatch" }
    assert_not_nil error
    assert_equal "2.1.3", error["display_number"]
    assert_equal "2027", error["year"]
    assert_equal "-17898180.00", error["delta_rub"]
  end

  test "checks non numeric summary rows as aggregate funding validation targets" do
    summary = @version.program_nodes.create!(
      node_type: "object",
      parent: @root,
      source_table_index: 5,
      source_row_index: 76,
      display_number: "Итого по подпрограмме",
      name: "Итого по подпрограмме"
    )
    summary.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "10194000.00")

    result = PostExportDocxValidator.new(
      program_version: @version,
      generated_docx_attachment: @document.file_attachment,
      parser_client: FakeParserClient.new(
        "passport_totals_by_year" => { "2026" => "150000.00", "2027" => "200000.00" },
        "nodes" => [],
        "funding_lines" => []
      ),
      visual_renderer: FakeVisualRenderer.new("valid")
    ).validate

    assert_equal "invalid", result["status"]
    assert_empty result["errors"].select { |item| item["code"] == "object_funding_mismatch" }
    error = result["errors"].detect { |item| item["code"] == "aggregate_funding_mismatch" }
    assert_not_nil error
    assert_equal "Итого по подпрограмме", error["display_number"]
    assert_equal "2027", error["year"]
  end

  test "matches aggregate rows after generated docx row indexes shift" do
    activity = @version.program_nodes.create!(
      node_type: "activity",
      parent: @root,
      source_table_index: 6,
      source_row_index: 280,
      display_number: "5.3",
      code: "05.03",
      name: "Мероприятие 05.03. Утверждение программ комплексного развития систем коммунальной инфраструктуры",
      metadata: {
        "docx_year_cell_indexes" => { "2027" => 18 },
        "docx_year_raw_values" => { "2027" => "0,0" },
        "docx_unit_in_document" => "thousand_rub"
      }
    )
    activity.funding_lines.create!(year: 2027, source_type: "LOCAL_BUDGET", amount_rub: "1000000.00")

    result = PostExportDocxValidator.new(
      program_version: @version,
      generated_docx_attachment: @document.file_attachment,
      parser_client: FakeParserClient.new(
        "passport_totals_by_year" => { "2026" => "150000.00", "2027" => "200000.00" },
        "nodes" => [
          {
            "stable_key" => "activity:6:282:5-3",
            "node_type" => "activity",
            "source_table_index" => 6,
            "source_row_index" => 282,
            "display_number" => "5.3",
            "code" => "05.03",
            "name" => "Мероприятие 05.03. Утверждение программ комплексного развития систем коммунальной инфраструктуры",
            "metadata" => {
              "docx_year_raw_values" => { "2027" => "1 000,00" },
              "docx_unit_in_document" => "thousand_rub"
            }
          }
        ],
        "funding_lines" => []
      ),
      visual_renderer: FakeVisualRenderer.new("valid")
    ).validate

    assert_equal "valid", result["status"]
    assert_empty result["errors"].select { |item| item["code"] == "aggregate_funding_mismatch" }
  end

  test "does not require virtual residual adjustment nodes to exist as object rows in generated docx" do
    residual = @version.program_nodes.create!(
      node_type: "residual",
      parent: @root,
      source_table_index: 6,
      display_number: "2.4.1",
      name: "Капитальный ремонт сетей водоснабжения сверх объемов финансирования мероприятия государственной программы Московской области",
      metadata: { "docx_virtual_residual" => true, "docx_insert_status" => "virtual" }
    )
    residual.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "5710950.00")

    result = PostExportDocxValidator.new(
      program_version: @version,
      generated_docx_attachment: @document.file_attachment,
      parser_client: FakeParserClient.new(
        "passport_totals_by_year" => { "2026" => "150000.00", "2027" => "200000.00" },
        "nodes" => [],
        "funding_lines" => []
      ),
      visual_renderer: FakeVisualRenderer.new("valid")
    ).validate

    assert_equal "valid", result["status"]
    assert_empty result["errors"].select { |item| item["code"] == "object_funding_mismatch" }
  end

  class FakeParserClient
    def initialize(payload)
      @payload = payload
    end

    def parse_docx_path(_path)
      @payload
    end
  end

  class FakeVisualRenderer
    def initialize(status)
      @status = status
    end

    def render(docx_bytes:)
      {
        "status" => @status,
        "page_count" => @status == "valid" ? 2 : 0,
        "preview_count" => @status == "valid" ? 1 : 0,
        "errors" => @status == "valid" ? [] : [{ "code" => "convert_failed", "message" => "render failed" }]
      }
    end
  end
end
