require "ostruct"

class AgentContextBuilder
  CHANGE_SOURCE_TYPES = %w[xlsx_finance pdf_agreement].freeze

  def initialize(organization:, user:)
    @organization = organization
    @user = user
  end

  def build
    setting = AgentSetting.for_organization!(@organization)
    procedure = latest_document("pdf_procedure")
    program_document = latest_document("docx_program")
    program = active_program(program_document)
    latest_change_set = latest_change_set_for_organization
    latest_analysis_session = latest_analysis_session_for_organization

    {
      "organization" => {
        "id" => @organization.id,
        "name" => @organization.name,
        "municipality_name" => @organization.municipality_name
      },
      "interface_mode" => @user&.user? ? "employee" : "admin",
      "procedure" => procedure_context(procedure),
      "active_program" => program_context(program, program_document),
      "change_sources" => change_sources_context,
      "source_mode" => source_mode_context,
      "latest_analysis_session" => analysis_session_context(latest_analysis_session),
      "latest_change_set" => change_set_context(latest_change_set),
      "generated_documents" => generated_documents_context,
      "reconciliation" => reconciliation_context,
      "agent_settings" => {
        "primary_model" => setting.primary_model,
        "fast_model" => setting.fast_model,
        "use_knowledge_base" => setting.use_knowledge_base,
        "use_chat_history" => setting.use_chat_history,
        "show_technical_statuses" => setting.show_technical_statuses
      }
    }
  end

  private

  def latest_document(document_type)
    @organization.source_documents.where(document_type: document_type).order(updated_at: :desc).first
  end

  def active_program(program_document)
    @organization.municipal_programs.includes(:current_version).order(updated_at: :desc).first || program_from_document(program_document)
  end

  def program_from_document(program_document)
    payload = program_document&.parsed_payload || {}
    program = payload["program"] || {}
    return nil if program["name"].blank? && program_document.blank?

    OpenStruct.new(
      id: nil,
      name: program["name"].presence || "Название не определено",
      period_start_year: program["period_start_year"],
      period_end_year: program["period_end_year"],
      current_version: nil
    )
  end

  def procedure_context(document)
    {
      "loaded" => document.present?,
      "document_id" => document&.id,
      "filename" => document&.filename,
      "status" => StatusPresenter.label(document&.status),
      "rule_count" => procedure_knowledge_count(document),
      "chunk_count" => procedure_knowledge_count(document)
    }
  end

  def procedure_knowledge_count(document)
    return 0 unless document

    chunks_count = @organization.knowledge_chunks.where(source_document: document).count
    return chunks_count if chunks_count.positive?

    Array(document.parsed_payload&.fetch("rules", [])).size
  end

  def program_context(program, document)
    version = program&.current_version
    generated_change_set = active_generated_change_set(version)
    {
      "loaded" => document.present? || program.present?,
      "source_document_id" => generated_change_set.present? ? nil : document&.id,
      "generated_change_set_id" => generated_change_set&.id,
      "program_version_id" => version&.id,
      "name" => program&.name || "Название не определено",
      "filename" => active_program_filename(version, generated_change_set, document),
      "period" => period_label(program, document),
      "status" => StatusPresenter.label(version&.status || document&.status),
      "subprogram_count" => subprogram_count(version, document),
      "node_count" => version&.program_nodes&.count || Array(document&.parsed_payload&.fetch("nodes", [])).size,
      "funding_line_count" => funding_line_count(version)
    }
  end

  def active_program_filename(version, generated_change_set, document)
    return version.generated_docx_attachment.filename.to_s if version&.approved_active_status? && version.generated_docx_attachment.attached?
    return generated_change_set.generated_docx_attachment.filename.to_s if generated_change_set

    document&.filename
  end

  def active_generated_change_set(version)
    return nil unless version&.approved_active_status?

    ChangeSet.where(target_program_version: version, status: "applied")
      .order(updated_at: :desc, id: :desc)
      .detect(&:export_ready?)
  end

  def subprogram_count(version, document)
    persisted = version&.program_nodes&.where(node_type: "subprogram")&.count
    return persisted if persisted.present? && persisted.positive?

    Array(document&.parsed_payload&.fetch("subprograms", [])).size
  end

  def funding_line_count(version)
    return 0 unless version

    FundingLine.joins(:program_node).where(program_nodes: { program_version_id: version.id }).count
  end

  def period_label(program, document)
    start_year = program&.period_start_year || document&.parsed_payload&.dig("program", "period_start_year")
    end_year = program&.period_end_year || document&.parsed_payload&.dig("program", "period_end_year")
    return "Не определен" if start_year.blank? && end_year.blank?

    [start_year, end_year].compact.join("-")
  end

  def change_sources_context
    documents = []
    documents << latest_document("xlsx_finance")
    documents.concat(@organization.source_documents.pdf_agreement.order(updated_at: :desc).limit(10).to_a)
    documents.compact.uniq.map do |document|
      {
        "id" => document.id,
        "type" => document.document_type,
        "filename" => document.filename,
        "status" => StatusPresenter.label(document.status)
      }
    end
  end

  def source_mode_context
    resolver = SourceModeResolver.new(organization: @organization)
    resolver.summary.merge(
      "calculation_filenames" => resolver.calculation_documents.map(&:filename),
      "evidence_filenames" => resolver.evidence_documents.map(&:filename)
    )
  end

  def latest_change_set_for_organization
    ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: @organization.id })
      .order(updated_at: :desc)
      .first
  end

  def latest_analysis_session_for_organization
    @organization.analysis_sessions.order(updated_at: :desc).first
  end

  def change_set_context(change_set)
    return { "loaded" => false } unless change_set

    {
      "loaded" => true,
      "id" => change_set.id,
      "status" => StatusPresenter.label(change_set.status),
      "items_count" => change_set.change_items.count,
      "target_program_version_id" => change_set.target_program_version_id,
      "generated_docx_ready" => change_set.generated_docx_attachment.attached?,
      "change_report_ready" => change_set.change_report_attachment.attached?,
      "has_summary_row_updates" => summary_row_change_items?(change_set)
    }
  end

  def analysis_session_context(analysis_session)
    return { "loaded" => false } unless analysis_session

    {
      "loaded" => true,
      "id" => analysis_session.id,
      "status" => StatusPresenter.label(analysis_session.status),
      "matched_count" => analysis_session.summary["matched_count"] || 0,
      "unmatched_count" => analysis_session.summary["unmatched_count"] || 0,
      "change_items_count" => analysis_session.summary["change_items_count"] || 0
    }
  end

  def reconciliation_context
    version = @organization.municipal_programs.includes(:current_version).order(updated_at: :desc).first&.current_version
    return { "count" => 0, "items" => [] } unless version

    rows = Reconciliation.where(program_version: version)
      .order(year: :asc)

    {
      "count" => rows.size,
      "items" => rows.map do |row|
        {
          "year" => row.year,
          "status" => StatusPresenter.label(row.status),
          "word_amount_rub" => row.word_amount_rub&.to_s("F"),
          "external_amount_rub" => row.external_amount_rub&.to_s("F"),
          "delta_rub" => row.delta_rub&.to_s("F")
        }
      end
    }
  end

  def generated_documents_context
    rows = ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: @organization.id })
      .where(status: "applied")
      .order(updated_at: :desc)
      .select { |change_set| change_set.export_ready? && !summary_row_change_items?(change_set) }
      .first(5)

    {
      "count" => rows.size,
      "documents" => rows.map do |change_set|
        {
          "change_project_id" => change_set.id,
          "validation_status" => StatusPresenter.label(change_set.export_summary.dig("post_export_validation", "status")),
          "links" => {
            "docx" => Rails.application.routes.url_helpers.export_docx_change_set_path(change_set),
            "report" => Rails.application.routes.url_helpers.export_report_change_set_path(change_set)
          }
        }
      end
    }
  end

  def summary_row_change_items?(change_set)
    change_set.change_items
      .includes(:program_node)
      .where.not(status: "rejected")
      .where.not(agent_resolution_status: "excluded")
      .any? { |item| FinancialNodeClassifier.summary_row?(item.program_node) }
  end
end
