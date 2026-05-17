class DocumentProfileBuilder
  MIN_ACTIVE_CONFIDENCE = BigDecimal("0.65")

  def initialize(source_document:)
    @source_document = source_document
    @organization = source_document.organization
    @payload = source_document.parsed_payload || {}
    @warnings = []
  end

  def build!
    schema = schema_for_document
    confidence = confidence_for(schema)
    status = confidence >= MIN_ACTIVE_CONFIDENCE && @warnings.empty? ? "active" : "failed"

    MunicipalDocumentProfile.create!(
      organization: @organization,
      municipal_program: municipal_program,
      source_document: @source_document,
      profile_type: profile_type,
      status: status,
      schema_json: schema,
      confidence: confidence,
      warnings: @warnings
    )
  end

  private

  def schema_for_document
    case @source_document.document_type
    when "docx_program"
      docx_schema
    when "xlsx_finance"
      xlsx_schema
    when "pdf_procedure"
      { "procedure" => { "chunk_count" => Array(@payload["chunks"]).size } }
    when "pdf_agreement"
      pdf_agreement_schema
    else
      @warnings << "Тип документа не поддержан профилем"
      {}
    end
  end

  def docx_schema
    funding_lines = Array(@payload["funding_lines"])
    @warnings << "Не найдены строки финансирования DOCX" if funding_lines.empty?
    passport_detected = @payload["passport_totals_by_year"].present? ||
      @payload["passport_amounts"].present? ||
      @payload["passport_total_cell_coordinates"].present? ||
      @payload["passport_source_cell_coordinates"].present?
    @warnings << "Не найден паспорт программы" unless passport_detected

    finance_tables = finance_tables_from(funding_lines)
    passport = passport_table(passport_detected)
    units = {
      "docx_finance" => "thousand_rub",
      "docx_passport" => "thousand_rub"
    }

    {
      "municipal_document_profile" => {
        "document_role" => "current_program",
        "passport_table" => passport,
        "finance_tables" => finance_tables,
        "calculation_tables" => finance_tables,
        "reference_tables" => [],
        "year_columns" => finance_tables.flat_map { |table| table["year_cols"].to_h.keys }.uniq.sort,
        "source_column_detected" => finance_tables.any? { |table| table["source_col"].present? },
        "total_column_detected" => finance_tables.any? { |table| table["total_col"].present? },
        "money_units" => units,
        "budget_sources" => detected_source_aliases(funding_lines).keys
      },
      "program_structure" => {
        "hierarchy_order" => %w[program subprogram main_activity activity object funding_line],
        "subprogram_markers" => ["Подпрограмма"],
        "main_activity_markers" => ["Основное мероприятие"],
        "activity_markers" => ["Мероприятие"],
        "total_markers" => ["Итого", "Всего"]
      },
      "docx_finance_tables" => finance_tables,
      "passport_table" => passport,
      "units" => units,
      "object_code_patterns" => ["\\d{10}\\.\\d{10}"],
      "funding_source_aliases" => detected_source_aliases(funding_lines)
    }
  end

  def xlsx_schema
    object_groups = Array(@payload["object_groups"])
    @warnings << "Не найдены объектные строки Excel" if object_groups.empty?

    aliases = detected_excel_source_aliases(object_groups)
    {
      "municipal_document_profile" => {
        "document_role" => "xlsx_target_model",
        "finance_tables" => [
          {
            "sheet_name" => @payload["sheet_name"].presence || "Результат",
            "object_groups_count" => object_groups.size
          }
        ],
        "money_units" => { "xlsx" => "rub" },
        "budget_sources" => aliases.keys
      },
      "excel_schema" => {
        "sheet_name" => @payload["sheet_name"].presence || "Результат",
        "object_groups_count" => object_groups.size,
        "explicit_zero_target_count" => object_groups.count { |group| group["explicit_zero_target"].present? }
      },
      "units" => { "xlsx" => "rub" },
      "funding_source_aliases" => aliases
    }
  end

  def pdf_agreement_schema
    changes = Array(@payload["changes"])
    pdf_profile = @payload["pdf_profile"].to_h
    control_sums = @payload["pdf_control_sums"].to_h

    @warnings << "PDF не содержит структурированных изменений" if changes.empty?
    @warnings << "Контрольные суммы PDF-таблицы не сходятся" if control_sums["status"] == "failed"
    if control_sums.blank? && pdf_profile["table_count"].to_i.positive?
      @warnings << "Контрольные суммы PDF-таблицы не найдены"
    end

    {
      "municipal_document_profile" => {
        "document_role" => "pdf_patch_source",
        "finance_tables" => Array(pdf_profile["tables"]),
        "calculation_tables" => Array(pdf_profile["tables"]),
        "money_units" => { "pdf" => "rub" },
        "control_sums" => control_sums.presence,
        "detected_table_types" => Array(pdf_profile["detected_table_types"])
      }.compact,
      "pdf_patch" => {
        "changes_count" => changes.size,
        "table_count" => pdf_profile["table_count"].to_i,
        "detected_table_types" => Array(pdf_profile["detected_table_types"]),
        "tables" => Array(pdf_profile["tables"]),
        "control_sums" => control_sums.presence
      }.compact
    }
  end

  def finance_tables_from(funding_lines)
    funding_lines.group_by { |line| line["source_table_index"] }.filter_map do |table_index, lines|
      next if table_index.blank?

      sample = lines.find { |line| line["year_cell_indexes"].present? } || lines.first
      {
        "table_index" => table_index,
        "header_rows" => [],
        "display_number_col" => 0,
        "name_col" => 1,
        "period_col" => 2,
        "source_col" => sample["source_cell_index"],
        "total_col" => sample["total_cell_index"],
        "year_cols" => sample["year_cell_indexes"] || {}
      }.compact
    end
  end

  def passport_table(detected)
    first_coordinate = @payload["passport_total_cell_coordinates"].to_h.values.first ||
      @payload["passport_source_cell_coordinates"].to_h.values.first
    {
      "detected" => detected,
      "table_index" => first_coordinate&.fetch("table_index", nil),
      "year_cols" => passport_year_cols
    }.compact
  end

  def passport_year_cols
    @payload["passport_total_cell_coordinates"].to_h.each_with_object({}) do |(year, coordinate), result|
      result[year.to_s] = coordinate["cell_index"] if coordinate["cell_index"].present?
    end
  end

  def detected_source_aliases(funding_lines)
    funding_lines.map { |line| FundingSourceCatalog.normalize(line["source_type"], organization: @organization) }.uniq.index_with { [] }
  end

  def detected_excel_source_aliases(object_groups)
    object_groups.flat_map { |group| group["funding"].to_h.keys }.filter_map do |key|
      _year, source_type = key.to_s.split("::", 2)
      FundingSourceCatalog.normalize(source_type, organization: @organization) if source_type.present?
    end.uniq.index_with { [] }
  end

  def confidence_for(schema)
    confidence = BigDecimal("1.0")
    confidence -= BigDecimal("0.25") if @warnings.any?
    confidence -= BigDecimal("0.35") if @source_document.docx_program? && schema["docx_finance_tables"].blank?
    confidence -= BigDecimal("0.25") if @source_document.docx_program? && !schema.dig("passport_table", "detected")
    confidence -= BigDecimal("0.35") if @source_document.pdf_agreement? && schema.dig("pdf_patch", "changes_count").to_i.zero?
    confidence -= BigDecimal("0.45") if @source_document.pdf_agreement? && schema.dig("pdf_patch", "control_sums", "status") == "failed"
    [[confidence, BigDecimal("0")].max, BigDecimal("1")].min
  end

  def profile_type
    return "procedure" if @source_document.pdf_procedure?

    @source_document.document_type
  end

  def municipal_program
    return nil unless @source_document.docx_program?

    @organization.municipal_programs.order(updated_at: :desc).first
  end
end
