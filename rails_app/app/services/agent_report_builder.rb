require "digest"

class AgentReportBuilder
  def initialize(organization:, user:, parser_worker_client: ParserWorkerClient.new)
    @organization = organization
    @user = user
    @parser_worker_client = parser_worker_client
  end

  def mapping_report
    docx = latest_parsed("docx_program")
    xlsx = latest_parsed("xlsx_finance")
    pdf = latest_parsed("pdf_procedure")
    {
      "docx" => {
        "passport_totals_by_year" => docx&.parsed_payload&.fetch("passport_totals_by_year", {}) || {}
      },
      "excel" => {
        "program_totals" => xlsx&.parsed_payload&.fetch("program_totals", {}) || {},
        "residual_group_count" => residual_group_count(xlsx),
        "known_duplicate_groups" => []
      },
      "procedure_pdf" => {
        "rules" => pdf&.parsed_payload&.fetch("rules", []) || []
      },
      "reconciliation" => reconciliation_rows
    }
  end

  def explain!
    report = mapping_report
    model = selected_openrouter_model
    output = @parser_worker_client.explain_report(report, model: model)
    LlmRun.create!(
      organization: @organization,
      user: @user,
      model: output["model"].presence || model,
      purpose: output.fetch("purpose", "reconciliation_explanation"),
      prompt_hash: Digest::SHA256.hexdigest(JSON.generate(report)),
      input_summary: {
        reconciliation_count: report.fetch("reconciliation").size,
        has_docx: report.dig("docx", "passport_totals_by_year").present?,
        has_xlsx: report.dig("excel", "program_totals").present?
      },
      output: output,
      status: "completed"
    )
  end

  private

  def latest_parsed(document_type)
    @organization.source_documents.where(document_type: document_type, status: "parsed").order(updated_at: :desc).first
  end

  def residual_group_count(xlsx)
    groups = xlsx&.parsed_payload&.fetch("object_groups", []) || []
    groups.count { |group| group["status"] == "UNASSIGNED_RESIDUAL" }
  end

  def reconciliation_rows
    Reconciliation.joins(:source_document)
      .where(source_documents: { organization_id: @organization.id })
      .order(year: :asc)
      .map do |item|
        {
          "status" => item.status,
          "year" => item.year,
          "docx_amount_rub" => item.word_amount_rub.to_s("F"),
          "external_amount_rub" => item.external_amount_rub.to_s("F"),
          "delta_rub" => item.delta_rub.to_s("F")
        }
      end
  end

  def selected_openrouter_model
    settings = @organization.settings || {}
    settings["openrouter_model_primary"].presence || ENV["OPENROUTER_MODEL_PRIMARY"].presence || OpenRouterModelsClient::DEFAULT_PRIMARY_MODEL_ID
  end
end
