class AnalysisSessionsController < ApplicationController
  before_action :require_admin!

  def create
    version = current_organization.program_versions.find(params[:program_version_id])
    source_documents = selected_source_documents
    source_mode_summary = selected_source_mode_summary(source_documents)
    session = current_organization.analysis_sessions.create!(
      user: current_user,
      program_version: version,
      goal: params[:goal].presence || "Провести анализ документов",
      selected_source_document_ids: source_documents.map(&:id),
      source_mode: source_mode_summary["source_mode"].presence || "auto",
      source_policy: source_mode_summary["source_policy"].presence || {},
      summary: source_mode_summary
    )
    change_set = AnalysisSessionRunner.new(session).run!
    AuditLog.record!(current_user, current_organization, "analysis_session.completed", session, change_set_id: change_set&.id)
    redirect_to analysis_session_path(session), notice: "Анализ выполнен"
  end

  def show
    @analysis_session = scoped_analysis_sessions.find_by(id: params[:id])
    return head :not_found unless @analysis_session

    @source_documents = current_organization.source_documents.where(id: @analysis_session.selected_source_document_ids).order(:id)
    @change_set = @analysis_session.change_sets.order(updated_at: :desc).first
  end

  def run_analysis
    session = scoped_analysis_sessions.find(params[:id])
    change_set = AnalysisSessionRunner.new(session).run!
    AuditLog.record!(current_user, current_organization, "analysis_session.completed", session, change_set_id: change_set&.id)
    redirect_to analysis_session_path(session), notice: "Анализ выполнен"
  end

  def create_change_set
    run_analysis
  end

  private

  def scoped_analysis_sessions
    current_organization.analysis_sessions.includes(:change_sets, :program_version)
  end

  def selected_source_documents
    ids = Array(params[:selected_source_document_ids]).reject(&:blank?).map(&:to_i)
    scope = current_organization.source_documents.where(document_type: %w[xlsx_finance pdf_agreement other], status: "parsed")
    documents = ids.any? ? scope.where(id: ids) : SourceModeResolver.new(organization: current_organization, user: current_user).calculation_documents
    return documents if ids.empty? || documents.size == ids.uniq.size

    raise ActiveRecord::RecordNotFound
  end

  def selected_source_mode_summary(source_documents = nil)
    ids = Array(params[:selected_source_document_ids]).reject(&:blank?)
    if ids.any?
      documents = Array(source_documents)
      source_mode = SourceModeResolver.normalize(params[:source_mode]) || inferred_mode_for_documents(documents) || "auto"
      resolver_summary = SourceModeResolver.new(organization: current_organization, requested_mode: source_mode, user: current_user).summary
      calculation_documents = if SourceModeResolver.xlsx_target_mode?(source_mode)
        documents.select(&:xlsx_finance?)
      elsif source_mode == "pdf_patch"
        documents.select(&:pdf_agreement?)
      else
        documents
      end
      return resolver_summary.merge(
        "source_mode" => SourceModeResolver.normalize(source_mode) || "auto",
        "calculation_source_document_ids" => calculation_documents.map(&:id),
        "evidence_source_document_ids" => SourceModeResolver.normalize(source_mode) == "xlsx_target_with_pdf_evidence" ? documents.select(&:pdf_agreement?).map(&:id) : [],
        "available_source_document_ids" => documents.map(&:id)
      )
    end

    SourceModeResolver.new(organization: current_organization, user: current_user).summary
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
