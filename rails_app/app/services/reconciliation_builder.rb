class ReconciliationBuilder
  def initialize(organization:, user:)
    @organization = organization
    @user = user
  end

  def refresh!
    docx = latest_parsed("docx_program")
    xlsx = latest_parsed("xlsx_finance")
    return [] unless docx && xlsx

    version = ensure_program_version!
    Reconciliation.where(program_version: version).delete_all

    docx_totals = docx.parsed_payload.fetch("passport_totals_by_year", {})
    xlsx_totals = xlsx.parsed_payload.fetch("program_totals", {})
    years = (docx_totals.keys + xlsx_totals.keys).map(&:to_i).uniq.sort
    tolerance = BigDecimal(@organization.settings.fetch("money_tolerance_rub", "10").to_s)

    years.map do |year|
      word_amount = BigDecimal(docx_totals.fetch(year.to_s, "0").to_s)
      external_amount = BigDecimal(xlsx_totals.fetch(year.to_s, "0").to_s)
      delta = external_amount - word_amount
      status = delta.abs > tolerance ? "PROGRAM_TOTAL_DIFF" : "PROGRAM_TOTAL_OK"
      Reconciliation.create!(
        program_version: version,
        source_document: xlsx,
        status: status,
        year: year,
        word_amount_rub: word_amount,
        external_amount_rub: external_amount,
        delta_rub: delta,
        details: {
          docx_source_document_id: docx.id,
          xlsx_source_document_id: xlsx.id
        }
      )
    end
  end

  private

  def latest_parsed(document_type)
    source_documents.where(document_type: document_type, status: "parsed").order(updated_at: :desc, id: :desc).first
  end

  def ensure_program_version!
    docx = latest_parsed("docx_program")
    version = program_version_for_document(docx)
    return version if version

    parsed_program = docx&.parsed_payload&.fetch("program", {}) || {}
    program_name = parsed_program["name"].presence || "Название не определено"
    start_year = parsed_program["period_start_year"].presence || 2026
    end_year = parsed_program["period_end_year"].presence || 2030

    program = @organization.municipal_programs.order(:id).first ||
      @organization.municipal_programs.create!(
        name: program_name,
        period_start_year: start_year,
        period_end_year: end_year
      )
    if program.name == "Название не определено" && program_name != "Название не определено"
      program.update!(name: program_name, period_start_year: start_year, period_end_year: end_year)
    end

    version = program.current_version || program.program_versions.order(:id).first ||
      program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    program.update!(current_version: version) unless program.current_version_id == version.id
    version
  end

  def program_version_for_document(docx)
    return nil unless docx

    @organization.program_versions
      .where("program_versions.import_summary ->> 'source_document_id' = ?", docx.id.to_s)
      .order(:id)
      .last
  end

  def source_documents
    scope = @organization.source_documents
    return scope unless @user&.user?

    scope.where(created_by: @user)
  end
end
