require "test_helper"
require "securerandom"

class ParseDocumentJobTest < ActiveJob::TestCase
  setup do
    @user = create_isolated_user!(email: "parse-job-#{SecureRandom.hex(6)}@example.com")
    @program = MunicipalProgram.create!(
      organization: @user.organization,
      name: "Развитие жилищно-коммунального хозяйства",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @previous_parser_client = Rails.application.config.x.parser_worker_client if Rails.application.config.x.parser_worker_client.respond_to?(:parse)
  end

  teardown do
    Rails.application.config.x.parser_worker_client = @previous_parser_client
  end

  test "parses an uploaded document and stores parsed payload" do
    document = attached_document!("docx_program", "program.docx")
    Rails.application.config.x.parser_worker_client = FakeParserClient.new(
      "passport_totals_by_year" => { "2026" => "100.00" },
      "subprograms" => []
    )

    ParseDocumentJob.perform_now(document.id)

    document.reload
    assert_equal "parsed", document.status
    assert_equal "100.00", document.parsed_payload.dig("passport_totals_by_year", "2026")
  end

  test "creates reconciliation when docx and xlsx payloads are available" do
    SourceDocument.create!(
      organization: @user.organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "program.docx",
      status: "parsed",
      parsed_payload: { "passport_totals_by_year" => { "2026" => "100.00" } }
    )
    finance = attached_document!("xlsx_finance", "finance.xlsx")
    Rails.application.config.x.parser_worker_client = FakeParserClient.new(
      "program_totals" => { "2026" => "80.00" },
      "object_groups" => []
    )

    assert_difference "Reconciliation.count", 1 do
      ParseDocumentJob.perform_now(finance.id)
    end

    reconciliation = Reconciliation.last
    assert_equal "PROGRAM_TOTAL_DIFF", reconciliation.status
    assert_equal 2026, reconciliation.year
    assert_equal BigDecimal("-20.00"), reconciliation.delta_rub
  end

  test "indexes knowledge chunks when procedure pdf is parsed" do
    document = attached_document!("pdf_procedure", "procedure.pdf")
    Rails.application.config.x.parser_worker_client = FakeParserClient.new(
      "chunks" => [
        {
          "chunk_type" => "program_structure",
          "title" => "Структура программы",
          "content" => "Муниципальная программа содержит паспорт, мероприятия и показатели.",
          "page_number" => 3
        }
      ]
    )

    assert_difference "KnowledgeChunk.count", 1 do
      ParseDocumentJob.perform_now(document.id)
    end

    chunk = document.reload.knowledge_chunks.sole
    assert_equal "program_structure", chunk.chunk_type
    assert_includes chunk.content, "паспорт"
  end

  test "persists program tree when docx program is parsed" do
    document = attached_document!("docx_program", "program.docx")
    Rails.application.config.x.parser_worker_client = FakeParserClient.new(
      "program" => {
        "name" => "Развитие инженерной инфраструктуры",
        "period_start_year" => 2026,
        "period_end_year" => 2030
      },
      "passport_totals_by_year" => { "2026" => "12 224,99" },
      "passport_total_cell_coordinates" => {
        "2026" => { "table_index" => 1, "row_index" => 3, "cell_index" => 5 }
      },
      "nodes" => [
        { "stable_key" => "program", "node_type" => "program", "name" => "Развитие инженерной инфраструктуры" },
        { "stable_key" => "object-1", "parent_stable_key" => "program", "node_type" => "object", "name" => "ВЗУ Черусти", "display_number" => "1.1.1" }
      ],
      "funding_lines" => [
        {
          "node_stable_key" => "object-1",
          "year" => 2026,
          "source_type" => "LOCAL_BUDGET",
          "amount_rub" => "12224990.00",
          "source_table_index" => 2,
          "source_row_index" => 7,
          "source_cell_index" => 5,
          "total_cell_index" => 4,
          "year_cell_indexes" => { "2026" => 5 },
          "raw_value" => "12 224,99",
          "unit_in_document" => "thousand_rub"
        }
      ]
    )

    assert_difference "MunicipalDocumentProfile.count", 1 do
      assert_difference "ProgramNode.count", 2 do
        assert_difference "FundingLine.count", 1 do
          ParseDocumentJob.perform_now(document.id)
        end
      end
    end

    assert_equal "Развитие инженерной инфраструктуры", @user.organization.municipal_programs.first.name
    profile = document.reload.municipal_document_profiles.sole
    assert_equal "docx_program", profile.profile_type
    assert_equal "active", profile.status
  end

  private

  def attached_document!(document_type, filename)
    document = SourceDocument.create!(
      organization: @user.organization,
      created_by: @user,
      document_type: document_type,
      filename: filename,
      status: "queued"
    )
    document.file_attachment.attach(
      io: StringIO.new("test content"),
      filename: filename,
      content_type: "application/octet-stream"
    )
    document
  end

  class FakeParserClient
    def initialize(payload)
      @payload = payload
    end

    def parse(_document)
      @payload
    end
  end
end
