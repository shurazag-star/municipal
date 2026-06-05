class AnalysisSessionRunner
  CHANGE_SOURCE_TYPES = %w[xlsx_finance pdf_agreement].freeze

  def initialize(analysis_session)
    @analysis_session = analysis_session
    @organization = analysis_session.organization
  end

  def run!
    @analysis_session.update!(status: "running")

    unsupported_sources = []
    match_results = match_documents(selected_source_documents, unsupported_sources)
    evidence_match_results = match_documents(evidence_source_documents, unsupported_sources)
    conflict_match_results = (match_results + evidence_match_results)

    conflict_detector = SourceConflictDetector.new(match_results: conflict_match_results)
    source_conflicts = conflict_detector.conflicts
    conflict_match_results.each do |result|
      result.funding_entries.each do |entry|
        conflict = conflict_detector.conflict_for(result, entry)
        next unless conflict

        result.source_reference["source_conflict"] = conflict
      end
    end

    change_set = ChangeSetBuilder.new(analysis_session: @analysis_session, match_results: match_results).build!
    external_target_model = external_target_model_for(match_results)
    pdf_patch_ledger = pdf_patch_ledger_for(match_results)
    final_summary = summary(match_results, evidence_match_results, change_set, unsupported_sources, source_conflicts, external_target_model, pdf_patch_ledger)
    @analysis_session.update!(
      status: "completed",
      source_mode: final_summary["source_mode"].presence || @analysis_session.effective_source_mode,
      source_policy: final_summary["source_policy"].presence || {},
      summary: final_summary
    )
    change_set
  rescue StandardError => error
    @analysis_session.update!(
      status: "failed",
      summary: (@analysis_session.summary || {}).merge("error" => error.class.name, "message" => error.message)
    )
    raise
  end

  private

  def match_documents(documents, unsupported_sources)
    Array(documents).flat_map do |document|
      if supported_source?(document)
        results = ExternalSourceMatcher.new(analysis_session: @analysis_session, source_document: document).match!
        unsupported_sources << unsupported_source_summary(document) if results.empty? && document.pdf_agreement?
        results
      else
        unsupported_sources << unsupported_source_summary(document)
        []
      end
    end
  end

  def selected_source_documents
    @selected_source_documents ||= begin
      ids = @analysis_session.selected_source_document_ids
      scope = @organization.source_documents.where(document_type: CHANGE_SOURCE_TYPES, status: "parsed").order(updated_at: :desc)
      if ids.any?
        filter_documents_by_source_mode(scope.where(id: ids).to_a)
      else
        SourceModeResolver.new(
          organization: @organization,
          requested_mode: requested_source_mode,
          user: @analysis_session.user
        ).calculation_documents
      end
    end
  end

  def evidence_source_documents
    @evidence_source_documents ||= begin
      ids = Array(source_mode_summary["evidence_source_document_ids"]).map(&:to_i).reject(&:zero?)
      if ids.empty?
        []
      else
        @organization.source_documents
          .where(id: ids, document_type: "pdf_agreement", status: "parsed")
          .order(:created_at, :id)
          .to_a
      end
    end
  end

  def supported_source?(document)
    document.xlsx_finance? || document.pdf_agreement?
  end

  def unsupported_source_summary(document)
    {
      "source_document_id" => document.id,
      "filename" => document.filename,
      "document_type" => document.document_type,
      "reason" => document.pdf_agreement? ? "PDF не содержит структурированных изменений" : "Тип источника пока не поддержан анализатором"
    }
  end

  def summary(match_results, evidence_match_results, change_set, unsupported_sources, source_conflicts, external_target_model = nil, pdf_patch_ledger = nil)
    source_documents = selected_source_documents.to_a
    source_mode_summary.merge(
      "source_document_ids" => source_documents.map(&:id),
      "evidence_matched_count" => evidence_match_results.count { |result| result.program_node.present? },
      "matched_count" => match_results.count { |result| result.program_node.present? },
      "unmatched_count" => match_results.count { |result| result.program_node.blank? },
      "needs_confirmation_count" => 0,
      "change_set_id" => change_set&.id,
      "change_items_count" => change_set&.change_items&.count || 0,
      "unsupported_source_count" => unsupported_sources.size,
	      "unsupported_sources" => unsupported_sources,
      "source_conflicts_count" => source_conflicts.size,
      "source_conflicts" => source_conflicts,
      "external_target_model" => external_target_model,
      "pdf_patch_ledger" => pdf_patch_ledger
    )
  end

  def external_target_model_for(match_results)
    return nil unless SourceModeResolver.xlsx_target_mode?(source_mode_summary["source_mode"])
    return nil unless match_results.any? { |result| result.source_document&.xlsx_finance? }

    ExternalTargetModelBuilder.new(analysis_session: @analysis_session, match_results: match_results).build
  end

  def pdf_patch_ledger_for(match_results)
    return nil unless source_mode_summary["source_mode"].to_s == "pdf_patch"
    return nil unless match_results.any? { |result| result.source_document&.pdf_agreement? }

    PdfPatchLedgerBuilder.new(analysis_session: @analysis_session, match_results: match_results).build
  end

  def source_mode_summary
    @source_mode_summary ||= begin
      resolver = SourceModeResolver.new(
        organization: @organization,
        requested_mode: requested_source_mode,
        user: @analysis_session.user
      )
      resolver.summary.merge((@analysis_session.summary || {}).slice(
        "calculation_source_document_ids",
        "evidence_source_document_ids",
        "available_source_document_ids"
      )).slice(
        "source_mode",
        "source_mode_label",
        "source_policy",
        "calculation_source_document_ids",
        "evidence_source_document_ids",
        "available_source_document_ids"
      )
    end
  end

  def requested_source_mode
    requested = @analysis_session.source_mode.presence
    requested = @analysis_session.summary&.fetch("source_mode", nil) if requested.blank? || requested == "auto"
    requested
  end

  def filter_documents_by_source_mode(documents)
    mode = SourceModeResolver.normalize(requested_source_mode)
    mode = inferred_mode_for_documents(documents) if mode.blank? || mode == "auto"

    case mode
    when "xlsx_target", "xlsx_target_with_pdf_evidence"
      documents.select(&:xlsx_finance?).sort_by { |document| [document.updated_at || Time.zone.at(0), document.id] }.last(1)
    when "pdf_patch"
      documents.select(&:pdf_agreement?)
    else
      documents
    end
  end

  def inferred_mode_for_documents(documents)
    has_excel = documents.any?(&:xlsx_finance?)
    has_pdf = documents.any?(&:pdf_agreement?)
    return "xlsx_target_with_pdf_evidence" if has_excel && has_pdf
    return "xlsx_target" if has_excel
    return "pdf_patch" if has_pdf

    nil
  end
end
