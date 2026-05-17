class SourceModeResolver
  MODES = %w[auto xlsx_target pdf_patch manual_instruction xlsx_target_with_pdf_evidence].freeze
  DEFAULT_MODE_WITH_EXCEL_AND_PDF = "xlsx_target_with_pdf_evidence"

  LEGACY_ALIASES = {
    "excel_target" => "xlsx_target",
    "excel_target_with_pdf_evidence" => "xlsx_target_with_pdf_evidence",
    "xlsx_finance" => "xlsx_target",
    "excel" => "xlsx_target",
    "xlsx" => "xlsx_target",
    "pdf_agreement" => "pdf_patch",
    "pdf" => "pdf_patch",
    "manual" => "manual_instruction",
    "chat_instruction" => "manual_instruction",
    "manual_chat_instruction" => "manual_instruction"
  }.freeze

  MODE_LABELS = {
    "auto" => "Автоматический выбор источника",
    "xlsx_target" => "Excel как целевая модель",
    "pdf_patch" => "PDF как основание изменений",
    "manual_instruction" => "Ручной ввод в чате",
    "xlsx_target_with_pdf_evidence" => "Excel как цель, PDF как подтверждение"
  }.freeze

  def self.normalize(mode)
    normalized = mode.to_s.strip
    return normalized if normalized.in?(MODES)
    return LEGACY_ALIASES.fetch(normalized) if LEGACY_ALIASES.key?(normalized)

    nil
  end

  def self.xlsx_target_mode?(mode)
    normalize(mode).in?(%w[xlsx_target xlsx_target_with_pdf_evidence])
  end

  def self.label(mode)
    MODE_LABELS.fetch(normalize(mode), "Режим источника не выбран")
  end

  attr_reader :organization

  def initialize(organization:, requested_mode: nil)
    @organization = organization
    @requested_mode = requested_mode
  end

  def mode
    @mode ||= begin
      requested = self.class.normalize(@requested_mode)
      configured = configured_mode
      if requested == "auto" || (requested.blank? && configured == "auto")
        inferred_mode || "auto"
      else
        requested || configured || inferred_mode || "auto"
      end
    end
  end

  def requested_mode
    self.class.normalize(@requested_mode) || configured_mode || "auto"
  end

  def label
    self.class.label(mode)
  end

  def calculation_documents
    case mode
    when "xlsx_target"
      [latest_excel].compact
    when "pdf_patch"
      pdf_documents
    when "manual_instruction"
      []
    when "xlsx_target_with_pdf_evidence"
      [latest_excel].compact
    else
      []
    end
  end

  def evidence_documents
    mode == "xlsx_target_with_pdf_evidence" ? pdf_documents : []
  end

  def available_documents
    ([latest_excel].compact + pdf_documents).uniq
  end

  def summary
    {
      "source_mode" => mode,
      "source_mode_label" => label,
      "source_policy" => source_policy,
      "calculation_source_document_ids" => calculation_documents.map(&:id),
      "evidence_source_document_ids" => evidence_documents.map(&:id),
      "available_source_document_ids" => available_documents.map(&:id)
    }
  end

  def source_policy
    {
      "requested_mode" => requested_mode,
      "resolved_mode" => mode,
      "xlsx_role" => self.class.xlsx_target_mode?(mode) ? "target_model" : "ignored",
      "pdf_role" => pdf_role,
      "double_count_guard" => mode == "xlsx_target_with_pdf_evidence" ? "pdf_evidence_only" : "single_calculation_source"
    }
  end

  private

  def configured_mode
    self.class.normalize(organization.settings["default_source_mode"])
  end

  def inferred_mode
    return DEFAULT_MODE_WITH_EXCEL_AND_PDF if latest_excel && pdf_documents.any?
    return "xlsx_target" if latest_excel
    return "pdf_patch" if pdf_documents.any?

    nil
  end

  def pdf_role
    case mode
    when "pdf_patch" then "patch_ledger"
    when "manual_instruction" then "ignored"
    when "xlsx_target_with_pdf_evidence" then "evidence_only"
    else "ignored"
    end
  end

  def latest_excel
    @latest_excel ||= organization.source_documents
      .xlsx_finance
      .where(status: "parsed")
      .order(updated_at: :desc, id: :desc)
      .first
  end

  def pdf_documents
    @pdf_documents ||= organization.source_documents
      .pdf_agreement
      .where(status: "parsed")
      .order(:created_at, :id)
      .to_a
  end
end
