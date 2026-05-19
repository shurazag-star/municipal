class AgentAutonomousResolver
  Result = Struct.new(:change_set, :resolved_count, :excluded_count, :needs_clarification_count, :items, keyword_init: true)

  CHANGE_SOURCE_TYPES = %w[xlsx_finance pdf_agreement].freeze

  def initialize(change_set:, user:)
    @change_set = change_set
    @user = user
    @organization = change_set.program_version.municipal_program.organization
    @policy = @organization.settings["source_priority_policy"].presence || "xlsx_over_pdf"
  end

  def resolve!
    ActiveRecord::Base.transaction do
      apply_source_policy!
      @change_set.change_items.where.not(status: "rejected").order(:id).find_each do |item|
        resolve_item!(item)
      end
      @change_set.refresh_summary!
      AuditLog.record!(@user, @organization, "change_set.autonomous_resolution_completed", @change_set, summary)
    end
    result
  end

  def result
    Result.new(
      change_set: @change_set.reload,
      resolved_count: @change_set.change_items.where(agent_resolution_status: "resolved").count,
      excluded_count: @change_set.change_items.where(agent_resolution_status: "excluded").count,
      needs_clarification_count: @change_set.change_items.where(agent_resolution_status: "needs_clarification").count,
      items: @change_set.change_items.order(:id).map { |item| item.slice(:id, :agent_resolution_status, :agent_resolution_reason) }
    )
  end

  private

  def apply_source_policy!
    conflicts = Array(@change_set.analysis_session&.summary&.fetch("source_conflicts", nil))
    return if conflicts.empty?

    priority = priority_document_type
    resolved_conflicts = []
    conflicts.each do |conflict|
      next unless conflict.dig("sources", priority)

      resolved_conflicts << conflict.slice("object_name", "year", "source_type")
      @change_set.change_items.where.not(status: "rejected").find_each do |item|
        reference = item.source_reference || {}
        next unless same_conflict_item?(item, reference, conflict)

        if reference["document_type"] == priority || source_document_type(reference["source_document_id"]) == priority
          item.update!(
            source_reference: reference.except("source_conflict").merge("source_priority_policy" => @policy),
            agent_resolution_evidence: (item.agent_resolution_evidence || {}).merge("source_priority_policy" => @policy)
          )
        else
          exclude_item!(item, "По правилу приоритета применен другой источник: #{source_label(priority)}.", "source_priority_policy" => @policy)
        end
      end
    end
    persist_source_resolution!(priority, resolved_conflicts) if resolved_conflicts.any?
  end

  def resolve_item!(item)
    return if item.agent_resolution_excluded? || item.rejected?
    return resolve_existing_node!(item) if item.program_node.present?
    return resolve_new_object!(item) if item.new_object?

    clarify_item!(item, "Не найден объект муниципальной программы для применения изменения.")
  end

  def resolve_existing_node!(item)
    reference = item.source_reference || {}
    return clarify_item!(item, "В источниках есть конфликт, который нельзя применить без правила приоритета.") if reference["source_conflict"].present?
    return clarify_item!(item, "Изменение не привязано к финансовой строке объекта или остатка программы.") unless financial_target_node?(item.program_node)
    return clarify_item!(item, "Не удалось определить год или источник финансирования.") if item.year.blank? || item.source_type.blank?
    return exclude_item!(item, "Сумма не меняется после сравнения с текущей программой.") if BigDecimal(item.delta_rub.to_s).zero?

    item.update!(
      status: "confirmed",
      user_confirmed: true,
      requires_user_confirmation: false,
      agent_resolution_status: "resolved",
      agent_resolution_reason: "Объект найден в текущей программе; год, источник и сумма подтверждены документом-основанием.",
      agent_resolution_evidence: evidence_for(item).merge("resolution_pass" => "existing_program_node"),
      agent_resolver_model: "rails-autonomous-resolver",
      agent_resolved_at: Time.current
    )
  rescue ArgumentError
    clarify_item!(item, "Сумма в строке не распознана как число.")
  end

  def resolve_new_object!(item)
    reference = item.source_reference || {}
    parent_code = reference["parent_activity_code"].presence || reference["group_key"].presence
    return clarify_item!(item, "PDF-строка похожа на несколько объектов программы; нужно уточнить объект перед применением.") if ambiguous_pdf_new_object?(item, reference)
    return clarify_item!(item, "Остаточная или неуказанная строка Excel не может быть автоматически вставлена как новый объект.") if unsafe_external_new_object?(item)
    return clarify_item!(item, "Для нового объекта не найден код или раздел родительского мероприятия.") if parent_code.blank?
    return clarify_item!(item, "Не указано название нового объекта.") if item.new_value.blank?
    return clarify_item!(item, "Название нового объекта распознано как числовая сумма, а не как объект программы.") if numeric_label?(item.new_value)

    item.update!(
      status: "confirmed",
      user_confirmed: true,
      requires_user_confirmation: false,
      agent_resolution_status: "resolved",
      agent_resolution_reason: residual_reference?(reference) ? "Остаточная строка Excel распределена в родительское мероприятие как расчетная строка без отдельного объекта." : "Новый объект имеет название, сумму, год и привязку к родительскому мероприятию.",
      agent_resolution_evidence: evidence_for(item).merge("resolution_pass" => residual_reference?(reference) ? "residual_parent_code" : "new_object_parent_code", "parent_activity_code" => parent_code),
      agent_resolver_model: "rails-autonomous-resolver",
      agent_resolved_at: Time.current
    )
  end

  def clarify_item!(item, reason)
    item.update!(
      status: "draft",
      user_confirmed: false,
      requires_user_confirmation: false,
      agent_resolution_status: "needs_clarification",
      agent_resolution_reason: reason,
      agent_resolution_evidence: evidence_for(item),
      agent_resolver_model: "rails-autonomous-resolver",
      agent_resolved_at: Time.current
    )
  end

  def exclude_item!(item, reason, extra_evidence = {})
    item.update!(
      status: "rejected",
      user_confirmed: false,
      requires_user_confirmation: false,
      agent_resolution_status: "excluded",
      agent_resolution_reason: reason,
      agent_resolution_evidence: evidence_for(item).merge(extra_evidence),
      agent_resolver_model: "rails-autonomous-resolver",
      agent_resolved_at: Time.current
    )
  end

  def evidence_for(item)
    reference = item.source_reference || {}
    {
      "source_document_id" => reference["source_document_id"],
      "document_type" => reference["document_type"],
      "filename" => reference["filename"],
      "row_number" => reference["row_number"],
      "page_number" => reference["page_number"],
      "year" => item.year,
      "source_type" => item.source_type,
      "old_amount_rub" => item.old_amount_rub&.to_s("F"),
      "new_amount_rub" => item.new_amount_rub&.to_s("F"),
      "delta_rub" => item.delta_rub&.to_s("F")
    }.compact
  end

  def financial_target_node?(node)
    FinancialNodeClassifier.concrete_financial_node?(node)
  end

  def unsafe_external_new_object?(item)
    reference = item.source_reference || {}
    return false unless reference["document_type"].to_s == "xlsx_finance"

    return false if safe_residual_reference?(item, reference)
    return false if safe_new_object_reference?(item, reference)
    return true if reference["group_status"].to_s == "UNASSIGNED_RESIDUAL"
    return true if reference["match_status"].to_s.in?(%w[UNASSIGNED_RESIDUAL NEEDS_CONFIRMATION])
    return true if reference["object_code"].to_s == "0000000000.0000000000"
    return true if numeric_label?(item.new_value)

    reference["match_status"].to_s == "MISSING_IN_DOCX"
  end

  def ambiguous_pdf_new_object?(item, reference)
    item.new_object? &&
      reference["document_type"].to_s == "pdf_agreement" &&
      reference["match_status"].to_s == "NEEDS_CONFIRMATION"
  end

  def safe_residual_reference?(item, reference)
    return false unless residual_reference?(reference)

    parent_code = reference["parent_activity_code"].presence || reference["group_key"].presence
    parent_code.present? &&
      parent_activity_exists?(parent_code) &&
      item.new_value.present? &&
      !numeric_label?(item.new_value)
  end

  def residual_reference?(reference)
    reference["group_status"].to_s == "UNASSIGNED_RESIDUAL" ||
      reference["match_status"].to_s == "UNASSIGNED_RESIDUAL" ||
      reference["group_key"].to_s.start_with?("UNASSIGNED_RESIDUAL") ||
      reference["object_code"].to_s == "0000000000.0000000000"
  end

  def safe_new_object_reference?(item, reference)
    return false if reference["group_status"].to_s == "UNASSIGNED_RESIDUAL"

    reference["group_status"].to_s == "GROUPED_OBJECT" &&
      reference["object_code"].present? &&
      reference["parent_activity_code"].present? &&
      item.new_value.present? &&
      !numeric_label?(item.new_value) &&
      parent_activity_exists?(reference["parent_activity_code"])
  end

  def parent_activity_exists?(raw_code)
    parsed = parse_external_parent_code(raw_code)
    return false unless parsed

    parent_candidates(@change_set.program_version.program_nodes, parsed).any?
  end

  def parent_candidates(scope, parsed)
    activity_candidates = scoped_parent_candidates(scope, parsed[:activity_code])
    activity_matches = activity_candidates.select { |node| parent_activity_matches?(node, parsed) }
    return activity_matches if activity_matches.any?
    return activity_candidates if parsed[:activity_code].present? && activity_candidates.one?

    main_candidates = scoped_parent_candidates(scope, parsed[:main_activity_code])
    main_matches = main_candidates.select { |node| parent_main_activity_matches?(node, parsed) }
    return main_matches if main_matches.any?
    return main_candidates if parsed[:main_activity_code].present? && main_candidates.one?

    []
  end

  def scoped_parent_candidates(scope, code)
    candidates = scope.where(node_type: %w[activity object])
    candidates = candidates.where(code: code) if code.present?
    candidates.to_a.select { |node| activity_parent_candidate?(node) }
  end

  def parent_activity_matches?(node, parsed)
    subprogram_matches = parsed[:subprogram_display].blank? || node_subprogram_display(node).to_s == parsed[:subprogram_display].to_s
    activity_matches = node.code.to_s == parsed[:activity_code].to_s || node.display_number.to_s == parsed[:activity_display].to_s

    subprogram_matches && activity_matches
  end

  def parent_main_activity_matches?(node, parsed)
    subprogram_matches = parsed[:subprogram_display].blank? || node_subprogram_display(node).to_s == parsed[:subprogram_display].to_s
    main_matches = node.code.to_s == parsed[:main_activity_code].to_s || node.display_number.to_s == parsed[:main_activity_display].to_s

    subprogram_matches && main_matches
  end

  def activity_parent_candidate?(node)
    node.node_type == "activity" || activity_like_object_node?(node)
  end

  def activity_like_object_node?(node)
    node.node_type == "object" &&
      node.code.present? &&
      normalize_name(node.name).include?("мероприятие") &&
      !FinancialNodeClassifier.summary_row?(node)
  end

  def node_subprogram_display(node)
    ancestor_of_type(node, "subprogram")&.display_number.presence ||
      node.metadata.to_h["finance_table_index"].presence&.to_s
  end

  def parse_external_parent_code(raw_code)
    digits = raw_code.to_s.gsub(/\D/, "")
    return nil if digits.length < 7 || !digits.start_with?("10")

    subprogram = digits[2].to_i
    main_activity = digits[3, 2].to_i
    activity = digits[5, 2].to_i
    return nil if subprogram.zero? || main_activity.zero? || activity.zero?

    {
      subprogram_display: subprogram.to_s,
      main_activity_code: format("%02d", main_activity),
      main_activity_display: main_activity.to_s,
      activity_code: format("%02d.%02d", main_activity, activity),
      activity_display: "#{main_activity}.#{activity}"
    }
  end

  def ancestor_of_type(node, node_type)
    current = node.parent
    while current
      return current if current.node_type == node_type

      current = current.parent
    end
    nil
  end

  def numeric_label?(value)
    value.to_s.strip.match?(/\A[-+]?\d+(?:[.,]\d+)?\z/)
  end

  def priority_document_type
    case @policy
    when "pdf_over_xlsx" then "pdf_agreement"
    when "latest_uploaded" then latest_uploaded_priority
    else "xlsx_finance"
    end
  end

  def latest_uploaded_priority
    ids = @change_set.analysis_session&.selected_source_document_ids || []
    document = @organization.source_documents.where(id: ids, document_type: CHANGE_SOURCE_TYPES).order(updated_at: :desc).first
    document&.document_type || "xlsx_finance"
  end

  def same_conflict_item?(item, reference, conflict)
    return false unless item.year.to_i == conflict["year"].to_i
    return false unless item.source_type.to_s == conflict["source_type"].to_s

    conflict_name = normalize_name(conflict["object_name"])
    item_name = normalize_name(item.program_node&.name || item.new_value || reference["object_name"])
    conflict_name.present? && item_name == conflict_name
  end

  def source_document_type(id)
    SourceDocument.find_by(id: id)&.document_type
  end

  def persist_source_resolution!(priority, resolved_conflicts)
    session = @change_set.analysis_session
    return unless session

    session.update!(
      summary: (session.summary || {}).merge(
        "source_resolution" => {
          "priority" => priority,
          "policy" => @policy,
          "selected_at" => Time.current.iso8601,
          "resolved_conflicts" => resolved_conflicts
        }
      )
    )
  end

  def source_label(type)
    type == "xlsx_finance" ? "Excel финансистов" : "PDF-основание"
  end

  def normalize_name(value)
    value.to_s.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def summary
    result => resolved_count:, excluded_count:, needs_clarification_count:
    {
      resolved_count: resolved_count,
      excluded_count: excluded_count,
      needs_clarification_count: needs_clarification_count,
      source_priority_policy: @policy
    }
  end
end
