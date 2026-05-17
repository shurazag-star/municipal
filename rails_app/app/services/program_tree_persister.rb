class ProgramTreePersister
  def initialize(source_document:, user:)
    @source_document = source_document
    @user = user
    @organization = source_document.organization
    @payload = source_document.parsed_payload || {}
  end

  def persist!
    return unless @source_document.docx_program?

    ActiveRecord::Base.transaction do
      program = ensure_program!
      version = ensure_version!(program)
      replace_tree!(version)
      program.update!(current_version: version)
      program.program_versions.where.not(id: version.id).where(status: "uploaded_active").update_all(status: "uploaded_inactive", updated_at: Time.current)
      version.update!(
        status: "uploaded_active",
        import_summary: (version.import_summary || {}).merge(
          "source_document_id" => @source_document.id,
          "node_count" => version.program_nodes.count,
          "funding_line_count" => FundingLine.joins(:program_node).where(program_nodes: { program_version_id: version.id }).count,
          "passport_total_cell_coordinates" => @payload["passport_total_cell_coordinates"] || {},
          "passport_source_cell_coordinates" => @payload["passport_source_cell_coordinates"] || {},
          "passport_source_total_cell_coordinates" => @payload["passport_source_total_cell_coordinates"] || {},
          "passport_grand_total_cell_coordinate" => @payload["passport_grand_total_cell_coordinate"] || {}
        ).merge(
          municipal_document_profile_summary
        )
      )
      version
    end
  end

  private

  def ensure_program!
    program_payload = @payload.fetch("program", {}) || {}
    name = program_payload["name"].presence || "Название не определено"
    start_year = program_payload["period_start_year"]
    end_year = program_payload["period_end_year"]

    program = @organization.municipal_programs.order(:id).first ||
      @organization.municipal_programs.create!(
        name: name,
        period_start_year: start_year,
        period_end_year: end_year
      )

    attrs = {}
    attrs[:name] = name if name != "Название не определено" || program.name.blank?
    attrs[:period_start_year] = start_year if start_year.present?
    attrs[:period_end_year] = end_year if end_year.present?
    program.update!(attrs) if attrs.any?
    program
  end

  def ensure_version!(program)
    existing = program.program_versions.detect do |version|
      version.import_summary.to_h["source_document_id"].to_i == @source_document.id
    end
    return existing if existing

    program.program_versions.create!(
      created_by: @user,
      version_number: next_version_number(program),
      status: "uploaded_active",
      import_summary: { "source_document_id" => @source_document.id }
    )
  end

  def next_version_number(program)
    (program.program_versions.maximum(:version_number) || 0) + 1
  end

  def replace_tree!(version)
    version.program_nodes.destroy_all
    node_by_stable_key = {}
    node_payloads.each do |payload|
      stable_key = payload["stable_key"].presence || generated_stable_key(payload)
      node_by_stable_key[stable_key] = version.program_nodes.create!(
        node_type: node_type_for(payload["node_type"]),
        code: payload["code"],
        display_number: payload["display_number"],
        name: payload["name"].presence || "Без названия",
        normalized_name: payload["normalized_name"],
        execution_period: payload["execution_period"],
        source_table_index: payload["source_table_index"],
        source_row_index: payload["source_row_index"],
        metadata: metadata_for(payload, stable_key)
      )
    end

    node_payloads.each do |payload|
      stable_key = payload["stable_key"].presence || generated_stable_key(payload)
      parent_key = payload["parent_stable_key"]
      next if parent_key.blank?
      node = node_by_stable_key[stable_key]
      parent = node_by_stable_key[parent_key]
      node.update!(parent: parent) if node && parent
    end

    funding_line_payloads.each do |payload|
      node = node_by_stable_key[payload["node_stable_key"]]
      next unless node

      node.funding_lines.create!(
        year: payload["year"],
        source_type: source_type_for(payload["source_type"]),
        amount_rub: BigDecimal(payload["amount_rub"].to_s),
        amount_kind: "planned",
        source_document: @source_document,
        source_row_ref: source_row_ref(payload),
        raw_source_name: payload["source_label"].presence || payload["source_type"],
        metadata: {
          "source_label" => payload["source_label"],
          "raw_value" => payload["raw_value"],
          "unit_in_document" => payload["unit_in_document"],
          "source_table_index" => payload["source_table_index"],
          "source_row_index" => payload["source_row_index"],
          "source_cell_index" => payload["source_cell_index"],
          "total_cell_index" => payload["total_cell_index"],
          "total_raw_value" => payload["total_raw_value"],
          "year_cell_indexes" => payload["year_cell_indexes"] || {}
        }.compact
      )
    end
  end

  def node_payloads
    Array(@payload["nodes"])
  end

  def funding_line_payloads
    Array(@payload["funding_lines"])
  end

  def metadata_for(payload, stable_key)
    (payload["metadata"].presence || {}).merge(
      "stable_key" => stable_key,
      "parent_stable_key" => payload["parent_stable_key"]
    ).compact
  end

  def node_type_for(raw_type)
    ProgramNode.node_types.key?(raw_type.to_s) ? raw_type.to_s : "object"
  end

  def source_type_for(raw_type)
    canonical = FundingSourceCatalog.normalize(FundingLine.source_types.fetch(raw_type.to_s, raw_type.to_s), organization: @source_document.organization)
    FundingLine.source_types.key(canonical) || "unknown"
  end

  def source_row_ref(payload)
    [
      payload["source_table_index"],
      payload["source_row_index"],
      payload["source_cell_index"]
    ].join(":")
  end

  def generated_stable_key(payload)
    [
      payload["node_type"],
      payload["source_table_index"],
      payload["source_row_index"],
      payload["display_number"],
      payload["name"]
    ].compact.join(":")
  end

  def municipal_document_profile_summary
    profile = @source_document.municipal_document_profiles.order(created_at: :desc).first
    return {} unless profile

    {
      "municipal_document_profile_id" => profile.id,
      "municipal_document_profile_status" => profile.status,
      "municipal_document_profile_confidence" => profile.confidence.to_s("F"),
      "municipal_document_profile_warnings" => profile.warnings
    }
  end
end
