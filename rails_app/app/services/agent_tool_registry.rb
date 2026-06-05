require "set"

class AgentToolRegistry
  CHANGE_SOURCE_TYPES = %w[xlsx_finance pdf_agreement].freeze

  def self.source_label_for(source_type)
    FundingSourceCatalog.label(source_type).downcase
  end

  def self.change_item_public_summary(item)
    {
      "id" => item.id,
      "label" => item.program_node&.name.presence || item.new_value.presence || "Строка №#{item.id}",
      "object_name" => item.program_node&.name.presence || item.new_value.presence,
      "program_node_id" => item.program_node_id,
      "change_type" => item.change_type,
      "year" => item.year,
      "source_type" => item.source_type,
      "source_label" => source_label_for(item.source_type),
      "old_amount_rub" => item.old_amount_rub&.to_s("F"),
      "new_amount_rub" => item.new_amount_rub&.to_s("F"),
      "delta_rub" => item.delta_rub&.to_s("F"),
      "page_number" => item.source_reference&.fetch("page_number", nil),
      "row_number" => item.source_reference&.fetch("row_number", nil),
      "filename" => item.source_reference&.fetch("filename", nil),
      "document_type" => item.source_reference&.fetch("document_type", nil),
      "evidence_text" => item.source_reference&.fetch("evidence_text", nil),
      "hierarchy" => hierarchy_for_item(item),
      "reason" => item.agent_resolution_reason.presence || "нужно уточнение по документам"
    }
  end

  def initialize(organization:, user:, routes: Rails.application.routes.url_helpers)
    @organization = organization
    @user = user
    @routes = routes
  end

  def execute(intent, context:, arguments: {})
    case intent
    when "get_workspace_context"
      context.merge("status" => "completed")
    when "run_analysis", "create_change_set", "get_or_create_change_project"
      run_analysis(context, arguments)
    when "show_changeset", "show_change_project"
      show_change_project
    when "show_pending", "show_pending_items"
      show_pending_items
    when "approve_change_project"
      apply_change_project
    when "approve_generated_version"
      approve_generated_version(arguments)
    when "generate_docx", "apply_change_project"
      apply_change_project
    when "validate_control_sums"
      validate_control_sums(context, arguments)
    when "validate_exported_docx"
      validate_exported_docx(arguments)
    when "list_generated_documents", "get_download_links"
      list_generated_documents
    when "explain_change"
      explain_change(arguments)
    when "recheck_object"
      recheck_object(context, arguments)
    when "recalculate_object"
      recalculate_object(context, arguments)
    when "explain_object_change"
      explain_object_change(context, arguments)
    when "search_knowledge_base"
      search_knowledge_base(arguments)
    when "compare_sources"
      compare_sources
    when "choose_source_priority"
      choose_source_priority(arguments)
    when "check_documents"
      check_documents(context, arguments)
    when "confirm_change_items"
      confirm_change_items(arguments)
    when "autonomous_resolution"
      autonomous_resolution
    else
      { "status" => "skipped" }
    end
  end

  private

  def run_analysis(context, arguments = {})
    resolver = source_mode_resolver(arguments)
    missing = missing_analysis_inputs(context, resolver)
    return { "status" => "blocked", "missing" => missing } if missing.any?
    if version_choice_needed?(arguments) && !force_fresh_analysis?(arguments)
      return version_choice_response
    end

    existing = force_fresh_analysis?(arguments) ? nil : reusable_change_project(resolver)
    if existing
      resolution = AgentAutonomousResolver.new(change_set: existing, user: @user).resolve!
      return {
        "status" => "completed",
        "change_project_id" => existing.id,
        "change_set_id" => existing.id,
        "change_items_count" => existing.change_items.count,
        "needs_confirmation_count" => 0,
        "resolved_count" => resolution.resolved_count,
        "excluded_count" => resolution.excluded_count,
        "needs_clarification_count" => resolution.needs_clarification_count,
        "source_mode" => resolver.mode,
        "source_mode_label" => resolver.label,
        "change_summary" => change_summary(existing),
        "items" => preview_change_items(existing).map { |item| change_item_summary(item) },
        "reused" => true
      }
    end

    version = program_version_from_context(context, arguments)
    source_documents = resolver.calculation_documents
    session = @organization.analysis_sessions.create!(
      user: @user,
      program_version: version,
      goal: "Анализ документов из рабочего места агента",
      selected_source_document_ids: source_documents.map(&:id),
      source_mode: resolver.mode,
      source_policy: resolver.source_policy,
      summary: resolver.summary
    )
    change_set = AnalysisSessionRunner.new(session).run!
    resolution = change_set ? AgentAutonomousResolver.new(change_set: change_set, user: @user).resolve! : nil
    AuditLog.record!(@user, @organization, "analysis_session.completed", session, change_set_id: change_set&.id)
    session.reload

    {
      "status" => "completed",
      "analysis_session_id" => session.id,
      "change_project_id" => change_set&.id,
      "change_set_id" => change_set&.id,
      "change_items_count" => session.summary["change_items_count"] || 0,
      "needs_confirmation_count" => 0,
      "resolved_count" => resolution&.resolved_count || 0,
      "excluded_count" => resolution&.excluded_count || 0,
      "needs_clarification_count" => resolution&.needs_clarification_count || 0,
      "source_mode" => session.summary["source_mode"],
      "source_mode_label" => session.summary["source_mode_label"],
      "evidence_source_document_ids" => session.summary["evidence_source_document_ids"] || [],
      "change_summary" => change_set ? change_summary(change_set) : {},
      "items" => change_set ? preview_change_items(change_set).map { |item| change_item_summary(item) } : [],
      "diagnostics" => analysis_diagnostics(session, resolver)
    }
  rescue StandardError => error
    { "status" => "failed", "error" => error.message, "error_class" => error.class.name }
  end

  def reusable_change_project(resolver = source_mode_resolver)
    change_set = latest_change_set
    return nil unless change_set&.draft? || change_set&.pending_confirmation? || change_set&.ready_for_approval? || change_set&.approved? || change_set&.needs_manual_review?
    return nil if change_set.change_items.where(agent_resolution_status: %w[unresolved needs_clarification]).where.not(status: "rejected").exists?
    return nil if summary_row_change_items?(change_set)

    selected_ids = resolver.calculation_documents.map(&:id).sort
    previous_ids = Array(change_set.analysis_session&.selected_source_document_ids).map(&:to_i).sort
    previous_mode = change_set.analysis_session&.effective_source_mode
    return nil if duplicate_active_amount_updates?(change_set)

    selected_ids == previous_ids && SourceModeResolver.normalize(previous_mode) == resolver.mode ? change_set : nil
  end

  def force_fresh_analysis?(arguments)
    return true if ActiveModel::Type::Boolean.new.cast(arguments.to_h["force_rebuild"])

    normalized = normalize_name(arguments.to_h["_user_content"])
    return false if normalized.blank?

    normalized.match?(/(проанализ|анализ|пересчит|сопостав).*(сформир|нов.*редакц|docx|докс|word|ворд|документ|отчет)/) ||
      normalized.match?(/(сформир|подготов|выгруз|созда).*(нов.*редакц|docx|докс|word|ворд|документ|отчет).*(проанализ|анализ|пересчит|сопостав)/)
  end

  def show_change_project
    change_set = latest_change_set
    return { "status" => "empty" } unless change_set

    {
      "status" => "completed",
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "change_set_status" => change_set.status,
      "status_label" => StatusPresenter.label(change_set.status),
      "summary" => change_set.summary,
      "items_count" => change_set.change_items.count,
      "pending_count" => pending_count(change_set)
    }
  end

  def show_pending_items
    change_set = latest_change_set
    return { "status" => "empty" } unless change_set

    pending_items = change_set.change_items
      .where(agent_resolution_status: "needs_clarification")
      .order(:id)
      .limit(10)
      .map { |item| change_item_summary(item) }
    manual_ids = Array(change_set.export_summary.dig("new_objects", "manual_item_ids"))
    manual_items = manual_ids.any? ? change_set.change_items.where(id: manual_ids).order(:id).limit(10).map { |item| change_item_summary(item) } : []

    {
      "status" => "completed",
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "pending_items" => (pending_items + manual_items).uniq { |item| item["id"] },
      "manual_insert_required_count" => change_set.export_summary["manual_insert_required_count"].to_i
    }
  end

  def confirm_change_items(arguments)
    change_set = change_set_from_arguments(arguments) || latest_change_set
    return { "status" => "empty" } unless change_set

    if arguments["object_query"].present?
      resolved_by_object = resolve_unmatched_items_with_object!(change_set, arguments["object_query"])
      if resolved_by_object.positive?
        resolution = AgentAutonomousResolver.new(change_set: change_set, user: @user).resolve!
        return {
          "status" => "completed",
          "change_project_id" => change_set.id,
          "change_set_id" => change_set.id,
          "resolved_count" => resolution.resolved_count,
          "pending_count" => pending_count(change_set),
          "object_query" => arguments["object_query"],
          "object_resolution_count" => resolved_by_object
        }
      end
    end

    ids = Array(arguments["change_item_ids"]).map(&:to_i).reject(&:zero?)
    scope = pending_confirmation_scope(change_set)
    mode = arguments["confirmation_mode"].presence || (ids.any? ? "specific" : "safe")

    case mode
    when "all_request"
      return {
        "status" => "needs_explicit_confirmation",
        "change_project_id" => change_set.id,
        "pending_count" => scope.count,
        "unsafe_count" => scope.count
      }
    when "all_confirmed"
      expected_count = arguments["expected_count"].to_i
      if expected_count.positive? && expected_count != scope.count
        return {
          "status" => "blocked",
          "change_project_id" => change_set.id,
          "missing" => ["точное количество строк для полного подтверждения изменилось"],
          "pending_count" => scope.count
        }
      end
    when "specific"
      return { "status" => "blocked", "missing" => ["номера строк для подтверждения"] } if ids.empty?

      scope = scope.where(id: ids)
    else
      safe_ids = scope.select { |item| safe_to_confirm?(item, change_set) }.map(&:id)
      scope = scope.where(id: safe_ids)
    end

    confirmed = scope.update_all(user_confirmed: true, status: ChangeItem.statuses.fetch("confirmed"), updated_at: Time.current)
    change_set.refresh_summary!
    {
      "status" => "completed",
      "change_project_id" => change_set.id,
      "confirmed_count" => confirmed,
      "pending_count" => pending_count(change_set),
      "confirmation_mode" => mode
    }
  end

  def resolve_unmatched_items_with_object!(change_set, object_query)
    match = CandidateObjectFinder.new(version: change_set.program_version).call("object_ref" => object_query)
    return 0 unless match.status == "matched"

    node = match.node
    scope = change_set.change_items
      .where(program_node_id: nil, agent_resolution_status: %w[unresolved needs_clarification])
      .where.not(status: "rejected")
    updated = 0
    scope.find_each do |item|
      row = clarified_amount_row(node, item)
      next unless row

      item.update!(
        program_node: node,
        change_type: "amount_update",
        field_name: "amount_rub",
        old_value: row["old_amount_rub"].to_s("F"),
        new_value: row["new_amount_rub"].to_s("F"),
        old_amount_rub: row["old_amount_rub"],
        new_amount_rub: row["new_amount_rub"],
        delta_rub: row["delta_rub"],
        source_reference: (item.source_reference || {}).merge(
          "user_clarified_object_query" => object_query,
          "user_clarified_program_node_id" => node.id
        ),
        agent_resolution_status: "unresolved",
        agent_resolution_reason: "Пользователь уточнил объект для спорной строки."
      )
      updated += 1
    end
    updated
  end

  def clarified_amount_row(node, item)
    source_type = funding_source_key(item.source_type)
    old_amount = current_amount(node, item.year, source_type)
    reference = item.source_reference || {}
    mode = reference["amount_mode"].presence || reference["original_amount_mode"].presence || "absolute"
    delta = item.delta_rub.present? ? BigDecimal(item.delta_rub.to_s) : BigDecimal(reference["delta_rub"].to_s.presence || "0")
    new_amount =
      if mode == "delta_plus"
        old_amount + delta.abs
      elsif mode == "delta_minus"
        old_amount - delta.abs
      elsif mode == "zeroing"
        BigDecimal("0")
      elsif item.new_amount_rub.present?
        BigDecimal(item.new_amount_rub.to_s)
      end
    return nil unless new_amount

    {
      "old_amount_rub" => old_amount,
      "new_amount_rub" => new_amount,
      "delta_rub" => new_amount - old_amount
    }
  rescue ArgumentError
    nil
  end

  def approve_change_project(arguments)
    change_set = change_set_from_arguments(arguments) || latest_change_set
    return { "status" => "empty" } unless change_set
    return { "status" => "blocked", "missing" => ["изменения в проекте"], "empty_project" => true, "change_project_id" => change_set.id } if actionable_items_count(change_set).zero?
    return { "status" => "blocked", "missing" => ["строки, которые требуют подтверждения"], "change_project_id" => change_set.id } if pending_count(change_set).positive?

    change_set.update!(status: "approved", approved_by: @user)
    AuditLog.record!(@user, @organization, "change_set.approved_by_agent", change_set)
    { "status" => "completed", "change_project_id" => change_set.id }
  end

  def apply_change_project
    change_set = latest_change_set_for_export
    return { "status" => "blocked", "missing" => ["проект изменений после анализа документов"] } unless change_set
    unless change_set.applied?
      resolution = AgentAutonomousResolver.new(change_set: change_set, user: @user).resolve!
      if resolution.needs_clarification_count.positive?
        return {
          "status" => "needs_clarification",
          "change_project_id" => change_set.id,
          "change_set_id" => change_set.id,
          "resolved_count" => resolution.resolved_count,
          "excluded_count" => resolution.excluded_count,
          "needs_clarification_count" => resolution.needs_clarification_count,
          "pending_items" => change_set.reload.change_items.where(agent_resolution_status: "needs_clarification").order(:id).limit(10).map { |item| change_item_summary(item) }
        }
      end
    end
    if !change_set.applied? && actionable_items_count(change_set).zero?
      return {
        "status" => "blocked",
        "change_project_id" => change_set.id,
        "change_set_status" => change_set.status,
        "missing" => ["изменения, которые можно применить"]
      }
    end

    result = change_set.applied? ? already_applied(change_set) : apply_pending(change_set)
    result.merge(download_payload(change_set.reload))
  rescue ChangeSetApplicationService::Error => error
    { "status" => "failed", "error" => error.message, "error_class" => error.class.name }
  end

  def already_applied(change_set)
    docx_patch = change_set.export_summary["docx_patch"] || {}
    {
      "status" => "completed",
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "target_program_version_id" => change_set.target_program_version_id,
      "docx_updated_cells" => docx_patch["applied_count"] || 0,
      "docx_inserted_objects" => docx_patch["inserted_count"] || 0,
      "manual_insert_required_count" => change_set.export_summary["manual_insert_required_count"].to_i
    }
  end

  def apply_pending(change_set)
    result = ChangeSetApplicationService.new(change_set: change_set, user: @user).apply!
    AuditLog.record!(@user, @organization, "change_set.applied_by_agent", change_set, target_program_version_id: result.target_program_version&.id)
    status = case change_set.reload.status
    when "applied" then "completed"
    when "needs_manual_review" then "needs_manual_review"
    when "export_failed" then "export_failed"
    else change_set.status
    end
    {
      "status" => status,
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "target_program_version_id" => result.target_program_version&.id,
      "docx_updated_cells" => result.docx_patch["applied_count"] || 0,
      "docx_inserted_objects" => result.docx_patch["inserted_count"] || 0,
      "manual_insert_required_count" => result.manual_insert_required_count,
      "validation_errors" => Array(change_set.export_summary.dig("post_export_validation", "errors"))
    }
  end

  def validate_control_sums(context, arguments = {})
    items = Array(context.dig("reconciliation", "items"))
    items = items.select { |item| item["year"].to_i == arguments["year"].to_i } if arguments["year"].present?
    discrepancies = discrepancy_items(arguments)
    {
      "status" => (items.empty? && discrepancies.empty?) ? "empty" : "completed",
      "items" => items.map do |item|
        {
          "year" => item["year"],
          "status_label" => item["status"],
          "word_amount_rub" => item["word_amount_rub"],
          "external_amount_rub" => item["external_amount_rub"],
          "delta_rub" => item["delta_rub"]
        }
      end,
      "discrepancies" => discrepancies
    }
  end

  def validate_exported_docx(arguments)
    change_set = change_set_from_arguments(arguments) || latest_change_set
    return { "status" => "empty" } unless change_set

    validation = change_set.export_summary["post_export_validation"] || {}
    {
      "status" => validation["status"].presence || "empty",
      "validation_errors" => validation["errors"] || [],
      "visual_render" => validation["visual_render"]
    }
  end

  def list_generated_documents
    documents = final_change_sets.first(5).map { |change_set| generated_document_row(change_set) }
    { "status" => "completed", "documents" => documents }
  end

  def explain_change(arguments)
    change_set = latest_change_set
    return { "status" => "empty" } unless change_set

    items = ordered_change_items(change_set)
    items = filter_items_by_year(items, arguments["year"]) if arguments["year"].present?
    items = filter_items_by_object(items, arguments["object_query"]) if arguments["object_query"].present?

    {
      "status" => "completed",
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "items" => items.first(8).map { |item| change_item_summary(item) },
      "matched_count" => items.size,
      "change_summary" => change_summary(change_set),
      "query" => arguments
    }
  end

  def recheck_object(context, arguments)
    change_set = latest_change_set
    return { "status" => "empty" } unless change_set

    query = object_query_from(context, arguments)
    return { "status" => "blocked", "missing" => ["название объекта для проверки"] } if query.blank?

    items = filter_items_by_object(ordered_change_items(change_set), query)
    decisions = AgentMatchDecision.where(change_item_id: items.map(&:id)).order(:id).map { |decision| decision_summary(decision) }
    {
      "status" => "completed",
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "object_query" => query,
      "object_name" => items.first&.program_node&.name.presence || items.first&.new_value.presence || query,
      "program_node_id" => items.first&.program_node_id,
      "source_mode" => change_set.analysis_session&.effective_source_mode,
      "matched_count" => items.size,
      "items" => items.first(10).map { |item| change_item_summary(item) },
      "agent_match_decisions" => decisions
    }
  end

  def recalculate_object(context, arguments)
    return apply_manual_object_change(context, arguments) if manual_object_change_request?(arguments)

    recheck = recheck_object(context, arguments)
    return recheck unless recheck["status"] == "completed"

    items = filter_items_by_object(ordered_change_items(latest_change_set), recheck["object_query"])
    recalculation = items.group_by { |item| [item.program_node_id, item.year, funding_source_value(item.source_type)] }.map do |(_node_id, year, source_type), grouped|
      {
        "object_name" => grouped.first.program_node&.name.presence || grouped.first.new_value,
        "program_node_id" => grouped.first.program_node_id,
        "year" => year,
        "source_type" => source_type,
        "old_amount_rub" => money(grouped.sum(BigDecimal("0")) { |item| BigDecimal(item.old_amount_rub.to_s.presence || "0") }),
        "new_amount_rub" => money(grouped.sum(BigDecimal("0")) { |item| BigDecimal(item.new_amount_rub.to_s.presence || "0") }),
        "delta_rub" => money(grouped.sum(BigDecimal("0")) { |item| BigDecimal(item.delta_rub.to_s.presence || "0") }),
        "calculated_by" => "deterministic_code"
      }
    end

    recheck.merge(
      "recalculation" => recalculation,
      "recalculation_status" => recalculation.empty? ? "no_changes" : "completed"
    )
  end

  def apply_manual_object_change(context, arguments)
    batch_result = manual_batch_instruction_result(context, arguments)
    return apply_manual_batch_change(context, arguments, batch_result) unless batch_result.status == "not_batch"

    instruction_result = manual_instruction_result(context, arguments)
    instruction = instruction_result.instruction
    manual_record = persist_manual_instruction!(instruction_result)
    AuditLog.record!(
      @user,
      @organization,
      "manual_instruction.extracted",
      manual_record,
      source_mode: "manual_instruction",
      status: instruction_result.status,
      missing_fields: instruction_result.missing_fields
    )
    if instruction_result.status != "complete"
      AuditLog.record!(
        @user,
        @organization,
        "manual_instruction.clarification_requested",
        manual_record,
        missing_fields: instruction_result.missing_fields,
        question: instruction_result.clarification_question
      )
      return {
        "status" => "needs_clarification",
        "source_mode" => "manual_instruction",
        "manual_instruction_id" => manual_record.id,
        "missing" => instruction_result.missing_fields,
        "clarification_question" => instruction_result.clarification_question
      }
    end

    if version_choice_needed?(arguments)
      return version_choice_response
    end

    version = program_version_from_context(context, arguments)
    return { "status" => "blocked", "missing" => ["текущая DOCX-программа"] } unless version

    match = CandidateObjectFinder.new(version: version).call(instruction)
    if match.status != "matched"
      manual_record.update!(structured_payload: instruction.merge("candidates" => match.candidates), clarification_status: "needs_clarification")
      AuditLog.record!(
        @user,
        @organization,
        "manual_instruction.match_clarification_requested",
        manual_record,
        reason: match.reason,
        candidates_count: Array(match.candidates).size
      )
      return {
        "status" => "needs_clarification",
        "source_mode" => "manual_instruction",
        "manual_instruction_id" => manual_record.id,
        "clarification_question" => clarification_for_candidate_match(match),
        "candidates" => match.candidates
      }
    end
    node = match.node
    manual_record.update!(program_node: node)

    operations = materialized_manual_operations(node, instruction_result.operations)
    operation_rows = operations.map do |operation|
      build_manual_operation_row(node, operation)
    end
    return { "status" => "blocked", "missing" => ["сумма не меняется"] } if operation_rows.all? { |row| row["delta_rub"].zero? }

    change_set = ChangeSet.create!(
      program_version: version,
      status: "draft",
      summary: "Изменение по команде из чата",
      created_by: @user
    )
    items = operation_rows.map { |row| create_manual_change_item!(change_set, node, row, instruction, manual_record) }
    manual_record.update!(change_set: change_set, operations_payload: operations)
    change_set.refresh_summary!
    if employee_manual_preview_required?(context, arguments)
      AuditLog.record!(
        @user,
        @organization,
        "manual_instruction.preview_ready",
        manual_record,
        change_set_id: change_set.id
      )
      return {
        "status" => "needs_confirmation",
        "manual_change_status" => "needs_confirmation",
        "change_project_id" => change_set.id,
        "change_set_id" => change_set.id,
        "manual_instruction_id" => manual_record.id,
        "object_query" => instruction["object_ref"],
        "object_name" => node.name,
        "program_node_id" => node.id,
        "source_mode" => "manual_instruction",
        "matched_count" => items.size,
        "items" => items.map { |item| change_item_summary(item.reload) },
        "recalculation" => operation_rows.map { |row| manual_recalculation_row(node, row) },
        "confirmation_question" => "Проверьте предварительный расчет. Если все правильно, напишите: «да, формируй готовый DOCX»."
      }
    end

    result = ChangeSetApplicationService.new(change_set: change_set, user: @user).apply!
    change_set.reload
    AuditLog.record!(
      @user,
      @organization,
      "manual_instruction.applied",
      manual_record,
      change_set_id: change_set.id,
      target_program_version_id: result.target_program_version&.id,
      validation_status: change_set.export_summary.dig("post_export_validation", "status")
    )

    {
      "status" => change_set.applied? ? "completed" : change_set.status,
      "manual_change_status" => result.target_program_version&.status || change_set.status,
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "target_program_version_id" => result.target_program_version&.id,
      "manual_instruction_id" => manual_record.id,
      "object_query" => instruction["object_ref"],
      "object_name" => node.name,
      "program_node_id" => node.id,
      "source_mode" => "manual_instruction",
      "matched_count" => items.size,
      "items" => items.map { |item| change_item_summary(item.reload) },
      "recalculation" => operation_rows.map { |row| manual_recalculation_row(node, row) },
      "docx_updated_cells" => result.docx_patch["applied_count"] || 0,
      "docx_inserted_objects" => result.docx_patch["inserted_count"] || 0,
      "manual_insert_required_count" => result.manual_insert_required_count,
      "validation_errors" => Array(change_set.export_summary.dig("post_export_validation", "errors"))
    }.merge(download_payload(change_set))
  rescue ChangeSetApplicationService::Error => error
    {
      "status" => "failed",
      "error" => error.message,
      "error_class" => error.class.name
    }
  rescue ArgumentError
    { "status" => "blocked", "missing" => ["сумма изменения"] }
  end

  def manual_batch_instruction_result(context, arguments)
    text = arguments.to_h["_user_content"].presence || arguments.to_h["text_evidence"].presence
    return ManualInstructionBatchExtractor::Result.new(status: "not_batch", instructions: [], missing_fields: []) if text.blank?

    ManualInstructionBatchExtractor.new(organization: @organization, user: @user).call(text: text, context: context)
  end

  def apply_manual_batch_change(context, arguments, batch_result)
    if batch_result.status != "complete"
      return {
        "status" => "needs_clarification",
        "source_mode" => "manual_instruction",
        "manual_batch_status" => "needs_clarification",
        "missing" => batch_result.missing_fields,
        "clarification_question" => batch_result.clarification_question
      }
    end

    return version_choice_response if version_choice_needed?(arguments)

    version = program_version_from_context(context, arguments)
    return { "status" => "blocked", "missing" => ["текущая DOCX-программа"] } unless version

    created_items = []
    manual_records = []
    change_set = nil
    ActiveRecord::Base.transaction do
      change_set = ChangeSet.create!(
        program_version: version,
        status: "draft",
        summary: "Пакет ручных изменений из чата",
        created_by: @user
      )

      batch_result.instructions.each_with_index do |instruction, index|
        manual_record = persist_manual_batch_instruction!(instruction, change_set, index)
        manual_records << manual_record
        created_items.concat(create_manual_batch_items!(change_set, version, instruction, manual_record, index))
      end

      raise ActiveRecord::Rollback if created_items.empty?
      change_set.refresh_summary!
    end

    return { "status" => "blocked", "missing" => ["изменения сумм"] } if change_set.blank? || created_items.empty?

    result = ChangeSetApplicationService.new(change_set: change_set, user: @user).apply!
    change_set.reload
    AuditLog.record!(
      @user,
      @organization,
      "manual_instruction.batch_applied",
      change_set,
      manual_instruction_ids: manual_records.map(&:id),
      target_program_version_id: result.target_program_version&.id,
      validation_status: change_set.export_summary.dig("post_export_validation", "status")
    )

    amount_updates = created_items.count { |item| item.change_type == "amount_update" }
    new_objects = created_items.count { |item| item.change_type == "new_object" }
    {
      "status" => change_set.applied? ? "completed" : change_set.status,
      "manual_change_status" => result.target_program_version&.status || change_set.status,
      "manual_batch_status" => "completed",
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "target_program_version_id" => result.target_program_version&.id,
      "manual_instruction_ids" => manual_records.map(&:id),
      "source_mode" => "manual_instruction",
      "matched_count" => created_items.size,
      "amount_update_items_count" => amount_updates,
      "new_object_items_count" => new_objects,
      "items" => created_items.map { |item| change_item_summary(item.reload) },
      "docx_updated_cells" => result.docx_patch["applied_count"] || 0,
      "docx_inserted_objects" => result.docx_patch["inserted_count"] || 0,
      "manual_insert_required_count" => result.manual_insert_required_count,
      "validation_errors" => Array(change_set.export_summary.dig("post_export_validation", "errors"))
    }.merge(download_payload(change_set))
  rescue ChangeSetApplicationService::Error => error
    {
      "status" => "failed",
      "manual_batch_status" => "failed",
      "error" => error.message,
      "error_class" => error.class.name
    }
  end

  def create_manual_batch_items!(change_set, version, instruction, manual_record, index)
    case instruction["kind"]
    when "new_object"
      create_manual_batch_new_object_items!(change_set, version, instruction, manual_record, index)
    else
      create_manual_batch_amount_items!(change_set, version, instruction, manual_record)
    end
  end

  def create_manual_batch_amount_items!(change_set, version, instruction, manual_record)
    match = CandidateObjectFinder.new(version: version).call(instruction)
    if match.status != "matched"
      manual_record.update!(
        structured_payload: instruction.merge("candidates" => match.candidates),
        clarification_status: "needs_clarification"
      )
      raise ChangeSetApplicationService::Error, clarification_for_candidate_match(match)
    end

    node = match.node
    manual_record.update!(program_node: node)
    Array(instruction["amounts"]).filter_map do |amount_row|
      source_type = funding_source_key(instruction["budget_source"])
      year = amount_row["year"].to_i
      old_amount = current_amount(node, year, source_type)
      new_amount = BigDecimal(amount_row["amount_rub"].to_s)
      delta = new_amount - old_amount
      next if delta.zero?

      create_manual_change_item!(
        change_set,
        node,
        {
          "operation" => "set_absolute",
          "year" => year,
          "source_type" => source_type,
          "old_amount_rub" => old_amount,
          "new_amount_rub" => new_amount,
          "delta_rub" => delta,
          "amount_rub" => new_amount,
          "text_evidence" => instruction["text_evidence"]
        },
        instruction,
        manual_record
      )
    end
  end

  def create_manual_batch_new_object_items!(change_set, version, instruction, manual_record, index)
    anchor_parent = manual_batch_anchor_parent(version, instruction)
    raise ChangeSetApplicationService::Error, "Не нашел основное мероприятие для нового объекта: #{instruction['main_activity_ref']}" unless anchor_parent

    source_reference = manual_batch_new_object_reference(anchor_parent, instruction, index)
    Array(instruction["amounts"]).filter_map do |amount_row|
      amount = BigDecimal(amount_row["amount_rub"].to_s)
      next if amount.zero?

      change_set.change_items.create!(
        change_type: "new_object",
        status: "draft",
        field_name: "object",
        year: amount_row["year"].to_i,
        source_type: funding_source_key(instruction["budget_source"]),
        new_value: instruction["object_ref"],
        new_amount_rub: amount,
        delta_rub: amount,
        source_reference: source_reference.merge("year" => amount_row["year"]),
        confidence: "0.95",
        requires_user_confirmation: false,
        user_confirmed: true,
        agent_resolution_status: "resolved",
        agent_resolution_reason: "Новый объект задан пользователем в ручной инструкции.",
        agent_resolver_model: "manual-batch-instruction-extractor",
        agent_resolved_at: Time.current,
        explanation: instruction["text_evidence"]
      )
    end.tap do |items|
      manual_record.update!(operations_payload: instruction["amounts"], structured_payload: instruction.merge("anchor_parent_node_id" => anchor_parent.id))
    end
  end

  def persist_manual_batch_instruction!(instruction, change_set, index)
    first_amount = Array(instruction["amounts"]).first
    ManualChangeInstruction.create!(
      organization: @organization,
      user: @user,
      change_set: change_set,
      source_mode: "manual_instruction",
      operation: instruction["operation"].presence || "set_absolute",
      object_ref: instruction["object_ref"],
      subprogram_ref: instruction["subprogram_ref"],
      main_activity_ref: instruction["main_activity_ref"],
      activity_ref: instruction["activity_ref"].presence || instruction["activity_display"],
      budget_source: instruction["budget_source"],
      year: first_amount&.fetch("year", nil),
      amount_rub: first_amount&.fetch("amount_rub", nil),
      text_evidence: instruction["text_evidence"],
      clarification_status: "complete",
      confidence: "0.95",
      structured_payload: instruction.merge("batch_index" => index),
      operations_payload: instruction["amounts"] || []
    )
  end

  def manual_batch_anchor_parent(version, instruction)
    ref = normalize_name(instruction["main_activity_ref"])
    code = instruction["activity_code"].to_s.split(".").first
    candidates = version.program_nodes
      .where(node_type: %w[main_activity activity object])
      .includes(:funding_lines)
      .to_a
      .reject { |node| FinancialNodeClassifier.summary_row?(node) }
    scored = candidates.filter_map do |node|
      target = normalize_name([node.display_number, node.code, node.name].compact.join(" "))
      score = 0
      score += 6 if ref.present? && target.include?(ref)
      score += 2 if code.present? && [node.code.to_s, node.display_number.to_s].include?(code.to_i.to_s)
      score += 1 if node.node_type == "main_activity"
      next if score.zero?

      [score, node]
    end
    scored.max_by(&:first)&.last
  end

  def manual_batch_new_object_reference(anchor_parent, instruction, index)
    parent_code = manual_batch_parent_activity_code(anchor_parent, instruction)
    {
      "document_type" => "manual_instruction",
      "source_mode" => "manual_instruction",
      "group_key" => [parent_code, parent_code, normalize_name(instruction["object_ref"])].join("::"),
      "group_status" => "ACTIVITY_AGGREGATE",
      "parent_activity_code" => parent_code,
      "object_code" => parent_code,
      "activity_code" => instruction["activity_code"],
      "activity_display" => instruction["activity_display"],
      "object_name" => instruction["object_ref"],
      "responsible" => instruction["responsible"],
      "execution_period" => instruction["execution_period"],
      "anchor_parent_node_id" => anchor_parent.id,
      "manual_batch_index" => index,
      "evidence_text" => instruction["text_evidence"]
    }.compact
  end

  def manual_batch_parent_activity_code(anchor_parent, instruction)
    code = instruction["activity_code"].to_s
    main, activity = code.split(".", 2).map(&:to_i)
    main = anchor_parent.code.to_s[/\d+/].to_i if main.zero?
    activity = 1 if activity.zero?
    subprogram = anchor_parent.metadata.to_h["finance_table_index"].to_i + 1
    subprogram = 1 if subprogram <= 0
    "13#{subprogram}#{format('%02d', main)}#{format('%02d', activity)}00000000"
  end

  def manual_instruction_result(context, arguments)
    text = arguments.to_h["_user_content"].presence || arguments.to_h["text_evidence"].presence
    if text.present?
      return ManualInstructionExtractor.new(organization: @organization, user: @user).call(text: text, context: context)
    end

    instruction = instruction_from_arguments(context, arguments)
    missing = manual_instruction_missing_fields(instruction, context)
    operations = missing.empty? ? manual_operations_from_instruction(instruction) : []
    ManualInstructionExtractor::Result.new(
      status: missing.empty? ? "complete" : "needs_clarification",
      instruction: instruction.merge(
        "clarification_status" => missing.empty? ? "complete" : "needs_clarification",
        "confidence" => missing.empty? ? "1.00" : "0.40"
      ),
      operations: operations,
      missing_fields: missing,
      clarification_question: manual_clarification_question(missing, context)
    )
  end

  def instruction_from_arguments(context, arguments)
    operation = arguments["amount_operation"].presence || "set"
    operation = "set_absolute" if operation == "set"
    amount = arguments["delta_rub"].presence || arguments["amount_rub"].presence
    {
      "source_mode" => "manual_instruction",
      "operation" => operation,
      "object_ref" => object_query_from(context, arguments),
      "budget_source" => arguments["source_type"],
      "year" => arguments["year"],
      "amount_rub" => amount.present? ? money(amount) : nil,
      "text_evidence" => arguments["_user_content"].presence || "Изменение задано пользователем в чате",
      "subprogram_ref" => arguments["subprogram_ref"],
      "main_activity_ref" => arguments["main_activity_ref"],
      "activity_ref" => arguments["activity_ref"]
    }.compact
  end

  def manual_instruction_missing_fields(instruction, context = {})
    missing = []
    missing << "object_ref" if instruction["object_ref"].blank?
    if employee_context?(context) && instruction["object_ref"].present?
      missing << "activity_ref" if instruction["activity_ref"].blank?
      missing << "main_activity_ref" if instruction["main_activity_ref"].blank?
      missing << "subprogram_ref" if instruction["subprogram_ref"].blank?
    end
    missing << "operation" if instruction["operation"].blank?
    missing << "budget_source" if instruction["budget_source"].blank?
    missing << "year" if instruction["year"].blank?
    missing << "amount_rub" if instruction["amount_rub"].blank?
    missing
  end

  def manual_operations_from_instruction(instruction)
    [
      {
        "source_mode" => "manual_instruction",
        "operation" => instruction["operation"],
        "object_ref" => instruction["object_ref"],
        "budget_source" => instruction["budget_source"],
        "year" => instruction["year"].to_i,
        "amount_rub" => instruction["amount_rub"],
        "text_evidence" => instruction["text_evidence"]
      }
    ]
  end

  def materialized_manual_operations(node, operations)
    rows = Array(operations).map(&:dup)
    return rows unless rows.any? { |operation| operation["amount_mode"] == "full_year_balance" }

    transfer_source = rows.find { |operation| operation["operation"] == "decrease" } || rows.first
    source_type = funding_source_key(transfer_source["budget_source"])
    source_year = transfer_source["year"].to_i
    transfer_amount = current_amount(node, source_year, source_type)
    rows.map do |operation|
      if operation["amount_mode"] == "full_year_balance"
        operation.merge("amount_rub" => transfer_amount.to_s("F"))
      else
        operation
      end
    end
  end

  def manual_clarification_question(missing, context = {})
    return "Уточните объект или позицию программы, к которой относится изменение." if missing.include?("object_ref")
    if employee_context?(context)
      return "Уточните точный номер и наименование мероприятия, где находится этот объект." if missing.include?("activity_ref")
      return "Уточните точный номер и наименование основного мероприятия." if missing.include?("main_activity_ref")
      return "Уточните номер и наименование муниципальной подпрограммы." if missing.include?("subprogram_ref")
    end
    return "Уточните источник финансирования: местный бюджет, областной/региональный бюджет, федеральный бюджет или иной источник?" if missing.include?("budget_source")
    return "Уточните год изменения." if missing.include?("year")
    return "Уточните сумму изменения." if missing.include?("amount_rub")

    "Нужно уточнить данные для безопасного пересчета."
  end

  def persist_manual_instruction!(result)
    instruction = result.instruction || {}
    ManualChangeInstruction.create!(
      organization: @organization,
      user: @user,
      source_mode: "manual_instruction",
      operation: instruction["operation"].presence || "unknown",
      object_ref: instruction["object_ref"],
      subprogram_ref: instruction["subprogram_ref"],
      main_activity_ref: instruction["main_activity_ref"],
      activity_ref: instruction["activity_ref"],
      budget_source: instruction["budget_source"],
      year: instruction["year"],
      from_year: instruction["from_year"],
      to_year: instruction["to_year"],
      amount_rub: instruction["amount_rub"],
      text_evidence: instruction["text_evidence"],
      clarification_status: result.status == "complete" ? "complete" : "needs_clarification",
      confidence: instruction["confidence"].presence || "0.0",
      structured_payload: instruction,
      operations_payload: result.operations || []
    )
  end

  def clarification_for_candidate_match(match)
    if match.reason == "ambiguous_object"
      choices = Array(match.candidates).first(5).each_with_index.map do |candidate, index|
        "#{index + 1}) #{candidate['path'].join(' / ')}"
      end.join("; ")
      "Я нашел несколько похожих позиций. Уточните, к какой относится изменение: #{choices}"
    else
      "Не нашел объект в текущей программе. Уточните название объекта или его раздел программы."
    end
  end

  def build_manual_operation_row(node, operation)
    source_type = funding_source_key(operation["budget_source"])
    year = operation["year"].to_i
    old_amount = current_amount(node, year, source_type)
    amount =
      if operation["amount_mode"] == "full_year_balance" && operation["amount_rub"].blank?
        old_amount
      else
        BigDecimal(operation["amount_rub"].to_s)
      end
    new_amount =
      case operation["operation"]
      when "increase" then old_amount + amount.abs
      when "decrease"
        raise ArgumentError, "transfer_amount_exceeds_current" if old_amount < amount.abs

        old_amount - amount.abs
      when "zero" then BigDecimal("0")
      else amount
      end
    {
      "operation" => operation["operation"],
      "year" => year,
      "source_type" => source_type,
      "old_amount_rub" => old_amount,
      "new_amount_rub" => new_amount,
      "delta_rub" => new_amount - old_amount,
      "amount_rub" => amount,
      "text_evidence" => operation["text_evidence"]
    }
  end

  def create_manual_change_item!(change_set, node, row, instruction, manual_record)
    change_set.change_items.create!(
      program_node: node,
      change_type: "amount_update",
      status: "draft",
      field_name: "amount_rub",
      year: row["year"],
      source_type: row["source_type"],
      old_value: row["old_amount_rub"].to_s("F"),
      new_value: row["new_amount_rub"].to_s("F"),
      old_amount_rub: row["old_amount_rub"],
      new_amount_rub: row["new_amount_rub"],
      delta_rub: row["delta_rub"],
      source_reference: {
        "document_type" => "manual_instruction",
        "source_mode" => "manual_instruction",
        "manual_instruction_id" => manual_record.id,
        "object_name" => node.name,
        "year" => row["year"],
        "source_type" => row["source_type"],
        "amount_operation" => row["operation"],
        "amount_mode" => instruction["amount_mode"],
        "text_evidence" => row["text_evidence"],
        "structured_instruction" => instruction.except("text_evidence")
      }.compact,
      confidence: BigDecimal("1.0"),
      requires_user_confirmation: false,
      agent_resolution_status: "resolved",
      agent_resolution_reason: "Изменение задано пользователем в чате и проверено расчетом.",
      agent_resolver_model: "manual-instruction-extractor",
      agent_resolved_at: Time.current
    )
  end

  def manual_recalculation_row(node, row)
    {
      "object_name" => node.name,
      "program_node_id" => node.id,
      "year" => row["year"],
      "source_type" => row["source_type"],
      "old_amount_rub" => money(row["old_amount_rub"]),
      "new_amount_rub" => money(row["new_amount_rub"]),
      "delta_rub" => money(row["delta_rub"]),
      "calculated_by" => "deterministic_code"
    }
  end

  def employee_manual_preview_required?(context, arguments)
    employee_context?(context) && !ActiveModel::Type::Boolean.new.cast(arguments.to_h["manual_preview_confirmed"])
  end

  def employee_context?(context)
    context.to_h["interface_mode"].to_s == "employee"
  end

  def explain_object_change(context, arguments)
    explain_change(arguments.merge("object_query" => object_query_from(context, arguments)))
  end

  def search_knowledge_base(arguments)
    unless AgentSetting.for_organization!(@organization).use_knowledge_base?
      return { "status" => "blocked", "missing" => ["база знаний отключена в настройках агента"] }
    end

    query = arguments["query"].presence || arguments["object_query"].presence || ""
    chunks = KnowledgeRetriever.new(organization: @organization).search(query: query, limit: 3).map do |chunk|
      {
        "title" => chunk.title,
        "content" => chunk.content,
        "page_number" => chunk.page_number,
        "filename" => chunk.source_document&.filename
      }
    end
    { "status" => "completed", "query" => query, "chunks" => chunks }
  end

  def compare_sources
    latest_session = @organization.analysis_sessions.order(updated_at: :desc).first
    return { "status" => "empty", "conflicts" => [] } unless latest_session

    { "status" => "completed", "conflicts" => Array(latest_session.summary["source_conflicts"]) }
  end

  def check_documents(context, arguments)
    documents = document_context_rows(context)
    query = arguments["document_query"].presence || arguments["object_query"].presence || arguments["query"].presence
    matches = matching_document_rows(documents, query)
    latest_session = @organization.analysis_sessions.order(updated_at: :desc).first

    {
      "status" => "completed",
      "query" => query,
      "documents" => documents,
      "matching_documents" => matches,
      "source_mode" => context["source_mode"],
      "latest_analysis_session" => context["latest_analysis_session"],
      "unsupported_sources" => Array(latest_session&.summary&.fetch("unsupported_sources", []))
    }
  end

  def choose_source_priority(arguments)
    priority = arguments["source_priority"].presence
    source_mode = SourceModeResolver.normalize(arguments["source_mode"])
    source_mode ||= priority == "pdf_agreement" ? "pdf_patch" : "xlsx_target" if priority.in?(%w[xlsx_finance pdf_agreement])
    return { "status" => "blocked", "missing" => ["режим источника: Excel, PDF, ручной ввод или Excel+PDF"] } unless source_mode.in?(SourceModeResolver::MODES)

    priority ||= source_mode == "pdf_patch" ? "pdf_agreement" : "xlsx_finance"
    priority = "manual_instruction" if source_mode == "manual_instruction"

    if @user&.admin?
      @organization.update!(
        settings: (@organization.settings || {}).merge(
          "source_priority_policy" => priority == "pdf_agreement" ? "pdf_over_xlsx" : "xlsx_over_pdf",
          "default_source_mode" => source_mode
        )
      )
    end
    AuditLog.record!(
      @user,
      @organization,
      "source_mode.selected",
      @organization,
      source_mode: source_mode,
      source_priority: priority
    )
    latest_session = @organization.analysis_sessions.order(updated_at: :desc).first
    resolved_conflicts = []
    if latest_session
      resolved_conflicts = Array(latest_session.summary["source_conflicts"])
      latest_session.update!(
        summary: (latest_session.summary || {}).merge(
          "source_resolution" => {
            "priority" => priority,
            "source_mode" => source_mode,
            "selected_by_user_id" => @user.id,
            "selected_at" => Time.current.iso8601,
            "resolved_conflicts" => resolved_conflicts.map { |conflict| conflict.slice("object_name", "year", "source_type") }
          }
        )
      )
    end
    change_set = latest_change_set
    rejected_count = change_set ? apply_source_priority_to_change_set!(change_set, priority, resolved_conflicts) : 0

    {
      "status" => "completed",
      "source_priority" => priority,
      "source_mode" => source_mode,
      "source_mode_label" => SourceModeResolver.label(source_mode),
      "analysis_session_id" => latest_session&.id,
      "change_project_id" => change_set&.id,
      "rejected_conflicting_count" => rejected_count
    }
  end

  def approve_generated_version(arguments = {})
    change_set = change_set_from_arguments(arguments) || latest_validated_generated_change_set
    return { "status" => "empty" } unless change_set

    GeneratedVersionApprovalService.new(organization: @organization, user: @user).approve_change_set!(change_set)
  rescue GeneratedVersionApprovalService::Error => error
    { "status" => "blocked", "missing" => [error.message] }
  end

  def download_payload(change_set)
    validation = change_set.export_summary["post_export_validation"] || {}
    self_check = change_set.export_summary["agent_self_check"] || {}
    payload = {
      "post_export_validation_status" => validation["status"],
      "checks" => checks_for(validation, self_check),
      "validation_errors" => Array(validation["errors"]) + Array(self_check["blocking_reasons"]).map { |reason| { "message" => reason } }
    }
    return payload unless change_set.export_ready?

    payload.merge(
      "download_links" => download_links(change_set),
      "approval_actions" => approval_actions(change_set)
    )
  end

  def checks_for(validation, self_check = {})
    return [] if validation["status"] == "invalid"

    checks = Array(self_check["checks"]).select { |item| item["passed"] }.map { |item| item["label"] }
    checks = ["контрольные суммы сходятся", "документ прошел повторный разбор"] if checks.empty?
    checks << "Word-документ открывается" if validation.dig("visual_render", "status") == "valid"
    checks << "визуальная проверка через LibreOffice пройдена" if validation.dig("visual_render", "status") == "valid"
    checks.uniq
  end

  def download_links(change_set)
    [
      {
        "label" => "Скачать новую редакцию DOCX",
        "url" => @routes.export_docx_change_set_path(change_set),
        "description" => "Проверенная новая редакция муниципальной программы"
      },
      {
        "label" => "Скачать отчет об изменениях",
        "url" => @routes.export_report_change_set_path(change_set),
        "description" => "HTML-отчет с перечнем примененных изменений"
      }
    ]
  end

  def approval_actions(change_set)
    return [] unless change_set.target_program_version&.generated_validated_status?

    [
      {
        "type" => "action",
        "label" => "Сделать актуальной",
        "url" => @routes.approve_generated_change_set_path(change_set),
        "method" => "post",
        "style" => "primary",
        "description" => "Утвердить проверенную новую редакцию как активную"
      },
      {
        "type" => "action",
        "label" => "Отклонить черновик",
        "url" => @routes.reject_generated_change_set_path(change_set),
        "method" => "post",
        "description" => @user&.user? ? "Попросить агента уточнить, что исправить в черновике" : "Оставить текущую активную редакцию без изменений"
      }
    ]
  end

  def generated_document_row(change_set)
    {
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "created_at" => change_set.applied_at&.iso8601,
      "validation_status" => change_set.export_summary.dig("post_export_validation", "status"),
      "download_links" => download_links(change_set),
      "links" => {
        "docx" => @routes.export_docx_change_set_path(change_set),
        "report" => @routes.export_report_change_set_path(change_set)
      }
    }
  end

  def final_change_sets
    ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: @organization.id })
      .where(status: "applied")
      .order(updated_at: :desc)
      .select { |change_set| change_set.export_ready? && !summary_row_change_items?(change_set) }
  end

  def latest_validated_generated_change_set
    final_change_sets.detect { |change_set| change_set.target_program_version&.generated_validated_status? } ||
      recoverable_rejected_generated_change_sets.first
  end

  def latest_unapproved_generated_draft
    applied = ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: @organization.id })
      .where(status: "applied")
      .order(updated_at: :desc)
      .detect do |change_set|
        change_set.export_ready? &&
          change_set.target_program_version&.generated_validated_status? &&
          change_set.program_version.municipal_program.current_version_id != change_set.target_program_version_id
      end
    applied || recoverable_rejected_generated_change_sets.first
  end

  def recoverable_rejected_generated_change_sets
    ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: @organization.id })
      .where(status: "rejected")
      .order(updated_at: :desc)
      .select { |change_set| recoverable_rejected_generated_change_set?(change_set) }
  end

  def recoverable_rejected_generated_change_set?(change_set)
    target_version = change_set.target_program_version
    target_version&.generated_rejected_status? &&
      change_set.generated_docx_attachment.attached? &&
      change_set.change_report_attachment.attached? &&
      change_set.export_summary.dig("post_export_validation", "status").in?(%w[valid valid_with_warnings]) &&
      change_set.export_summary.dig("agent_self_check", "status") == "passed" &&
      change_set.export_summary.dig("independent_verifier", "status").in?([nil, "passed"]) &&
      change_set.export_summary["manual_insert_required_count"].to_i.zero? &&
      change_set.program_version.municipal_program.current_version_id != change_set.target_program_version_id
  end

  def version_choice_needed?(arguments)
    return false if arguments.to_h["version_target"].present?

    latest_unapproved_generated_draft.present?
  end

  def version_choice_response
    draft = latest_unapproved_generated_draft
    {
      "status" => "needs_clarification",
      "clarification_question" => "У нас есть активная версия и проверенный черновик новой редакции, который еще не утвержден. В какую версию внести изменения: в активную или в черновик?",
      "active_program_version_id" => draft&.program_version_id,
      "draft_program_version_id" => draft&.target_program_version_id,
      "version_choices" => %w[active draft]
    }
  end

  def missing_analysis_inputs(context, resolver = source_mode_resolver)
    missing = []
    missing << "порядок разработки" unless context.dig("procedure", "loaded")
    missing << "текущая DOCX-программа" unless context.dig("active_program", "loaded") && context.dig("active_program", "program_version_id").present?
    missing << "документы-основания для режима «#{resolver.label}»" if resolver.calculation_documents.empty?
    missing
  end

  def parsed_change_sources(arguments = {})
    source_mode_resolver(arguments).calculation_documents
  end

  def analysis_diagnostics(session, resolver)
    source_document = resolver.calculation_documents.first
    payload = source_document&.parsed_payload || {}
    summary = session.summary || {}
    {
      "source_document_id" => source_document&.id,
      "source_document_type" => source_document&.document_type,
      "filename" => source_document&.filename,
      "object_groups_count" => Array(payload["object_groups"]).size,
      "program_totals_count" => payload["program_totals"].to_h.size,
      "final_totals_count" => payload["final_totals"].to_h.size,
      "matched_count" => summary["matched_count"].to_i,
      "unmatched_count" => summary["unmatched_count"].to_i,
      "change_items_count" => summary["change_items_count"].to_i,
      "source_mode" => summary["source_mode"]
    }.compact
  end

  def document_context_rows(context)
    rows = []
    procedure = context["procedure"] || {}
    if procedure["loaded"]
      rows << {
        "id" => procedure["document_id"],
        "type" => "pdf_procedure",
        "kind_label" => "порядок разработки / нормативная база",
        "filename" => procedure["filename"],
        "status" => procedure["status"],
        "role" => "procedure"
      }
    end

    program = context["active_program"] || {}
    if program["loaded"]
      rows << {
        "id" => program["source_document_id"],
        "type" => "docx_program",
        "kind_label" => "текущая DOCX-программа",
        "filename" => program["filename"].presence || @organization.source_documents.find_by(id: program["source_document_id"])&.filename,
        "status" => program["status"],
        "role" => "active_program"
      }
    end

    Array(context["change_sources"]).each do |document|
      rows << {
        "id" => document["id"],
        "type" => document["type"],
        "kind_label" => change_source_kind_label(document["type"]),
        "filename" => document["filename"],
        "status" => document["status"],
        "role" => "change_source"
      }
    end

    rows.uniq { |row| [row["type"], row["id"], row["filename"]] }
  end

  def matching_document_rows(documents, query)
    normalized_query = normalize_name(query)
    return documents if normalized_query.blank?

    tokens = normalized_query.split.reject { |token| token.length < 3 || document_query_stop_words.include?(token) }
    return documents if tokens.empty?

    documents.select do |document|
      haystack = normalize_name([document["filename"], document["kind_label"], document["type"], document["status"]].compact.join(" "))
      tokens.all? { |token| haystack.include?(token) } ||
        tokens.any? { |token| token.length >= 8 && haystack.include?(token.first(8)) }
    end
  end

  def change_source_kind_label(type)
    case type
    when "xlsx_finance" then "Excel финансистов"
    when "pdf_agreement" then "PDF-основание для изменений"
    else "документ-основание"
    end
  end

  def document_query_stop_words
    @document_query_stop_words ||= %w[
      есть видно видишь загружен загружена загружено разобран разобрана разобрано
      подключен подключена доступен доступна проверь файл документ pdf пдф excel эксел xlsx docx word ворд
      этот этого этом его ее её здесь
    ].to_set
  end

  def source_mode_resolver(arguments = {})
    SourceModeResolver.new(organization: @organization, requested_mode: arguments["source_mode"], user: @user)
  end

  def pending_count(change_set)
    return 0 unless change_set

    pending_confirmation_scope(change_set).count
  end

  def duplicate_active_amount_updates?(change_set)
    change_set.change_items
      .where(change_type: "amount_update")
      .where.not(status: "rejected")
      .where.not(agent_resolution_status: "excluded")
      .group_by { |item| [item.program_node_id, item.year, funding_source_value(item.source_type)] }
      .any? { |(node_id, _year, _source_type), items| node_id.present? && items.size > 1 }
  end

  def change_item_summary(item)
    {
      "id" => item.id,
      "label" => item.program_node&.name.presence || item.new_value.presence || "Строка №#{item.id}",
      "object_name" => item.program_node&.name.presence || item.new_value.presence,
      "program_node_id" => item.program_node_id,
      "category" => change_item_category(item),
      "category_label" => change_item_category_label(item),
      "change_type" => item.change_type,
      "year" => item.year,
      "source_type" => item.source_type,
      "source_label" => source_label(item.source_type),
      "old_amount_rub" => item.old_amount_rub&.to_s("F"),
      "new_amount_rub" => item.new_amount_rub&.to_s("F"),
      "delta_rub" => item.delta_rub&.to_s("F"),
      "page_number" => item.source_reference&.fetch("page_number", nil),
      "row_number" => item.source_reference&.fetch("row_number", nil),
      "filename" => item.source_reference&.fetch("filename", nil),
      "document_type" => item.source_reference&.fetch("document_type", nil),
      "evidence_text" => item.source_reference&.fetch("evidence_text", nil),
      "hierarchy" => hierarchy_for_item(item),
      "reason" => discrepancy_reason(item),
      "resolution_status" => item.agent_resolution_status,
      "resolution_reason" => item.agent_resolution_reason,
      "amount_mode" => item.source_reference&.fetch("amount_mode", nil) || item.source_reference&.fetch("original_amount_mode", nil)
    }
  end

  def preview_change_items(change_set, limit: 8)
    ordered_change_items(change_set).first(limit)
  end

  def ordered_change_items(change_set)
    change_set.change_items.includes(:program_node).order(:id).to_a.sort_by do |item|
      [
        change_item_priority(item),
        item.year.to_i.zero? ? 9999 : item.year.to_i,
        item.id
      ]
    end
  end

  def change_item_priority(item)
    case change_item_category(item)
    when "object_amount_update" then 0
    when "new_object" then 1
    when "zeroing" then 2
    when "residual_adjustment" then 3
    else 4
    end
  end

  def change_summary(change_set)
    items = change_set.change_items.where.not(status: "rejected").to_a
    {
      "total_items" => items.size,
      "resolved_count" => change_set.change_items.where(agent_resolution_status: "resolved").count,
      "excluded_count" => change_set.change_items.where(agent_resolution_status: "excluded").count,
      "needs_clarification_count" => change_set.change_items.where(agent_resolution_status: "needs_clarification").count,
      "object_amount_updates" => items.count { |item| change_item_category(item) == "object_amount_update" },
      "new_objects" => items.count { |item| change_item_category(item) == "new_object" },
      "residual_adjustments" => items.count { |item| change_item_category(item) == "residual_adjustment" },
      "zeroing_updates" => items.count { |item| change_item_category(item) == "zeroing" }
    }
  end

  def change_item_category(item)
    reference = item.source_reference || {}
    return "zeroing" if reference["amount_mode"].to_s == "zeroing" || reference["target_model_absent_in_excel"].present?
    return "residual_adjustment" if residual_reference?(reference)
    return "new_object" if item.new_object?
    return "object_amount_update" if item.amount_update? && concrete_object_node?(item.program_node)

    "other"
  end

  def change_item_category_label(item)
    case change_item_category(item)
    when "object_amount_update" then "изменение существующего объекта"
    when "new_object" then "новый объект из основания"
    when "zeroing" then "обнуление отсутствующей в Excel строки"
    when "residual_adjustment" then "остаточная строка Excel"
    else "расчетная строка"
    end
  end

  def concrete_object_node?(node)
    FinancialNodeClassifier.concrete_financial_node?(node)
  end

  def residual_reference?(reference)
    reference["group_status"].to_s == "UNASSIGNED_RESIDUAL" ||
      reference["match_status"].to_s == "UNASSIGNED_RESIDUAL" ||
      reference["group_key"].to_s.start_with?("UNASSIGNED_RESIDUAL") ||
      reference["object_code"].to_s == "0000000000.0000000000"
  end

  def manual_object_change_request?(arguments)
    args = arguments.to_h
    args["source_mode"].to_s == "manual_instruction" ||
      args["_user_content"].present? ||
      args["amount_rub"].present? ||
      args["delta_rub"].present?
  end

  def program_version_from_context(context, arguments = {})
    if arguments.to_h["version_target"] == "draft"
      draft = latest_unapproved_generated_draft
      return draft.target_program_version if draft&.target_program_version
    end

    id = context.dig("active_program", "program_version_id")
    @organization.program_versions.find_by(id: id) if id.present?
  end

  def manual_change_node(version, context, arguments)
    if (id = arguments["program_node_id"].presence || context.dig("conversation_memory", "working_state", "last_program_node_id").presence)
      node = version.program_nodes.find_by(id: id)
      return node if node
    end

    query = object_query_from(context, arguments)
    return nil if query.blank?

    filter_nodes_by_object(version.program_nodes.where(node_type: %w[object residual]).to_a, query)
      .select { |node| FinancialNodeClassifier.concrete_financial_node?(node) }
      .max_by { |node| object_query_score(node, query) }
  end

  def filter_nodes_by_object(nodes, query)
    query_tokens = normalize_name(query).split.map { |token| token.first(6) }.reject(&:blank?)
    return nodes if query_tokens.empty?

    nodes.select do |node|
      target = normalize_name([node.name, node.display_number, node.code].compact.join(" "))
      query_tokens.any? { |token| target.include?(token) }
    end
  end

  def object_query_score(node, query)
    target = normalize_name([node.name, node.display_number, node.code].compact.join(" "))
    tokens = normalize_name(query).split.reject(&:blank?)
    tokens.count { |token| target.include?(token.first(6)) }
  end

  def manual_source_type(node, year, arguments)
    explicit = arguments["source_type"].presence
    return funding_source_key(explicit) if explicit.present?

    source_values = node.funding_lines
      .select { |line| line.year.to_i == year.to_i }
      .map { |line| funding_source_value(line.source_type) }
      .uniq
    return funding_source_key(source_values.first) if source_values.one?

    nil
  end

  def current_amount(node, year, source_type)
    node.funding_lines.select do |line|
      line.year.to_i == year.to_i && funding_source_value(line.source_type) == funding_source_value(source_type)
    end.sum(BigDecimal("0")) { |line| BigDecimal(line.amount_rub.to_s) }
  end

  def manual_new_amount(old_amount, arguments)
    operation = arguments["amount_operation"].to_s
    if arguments["delta_rub"].present?
      delta = BigDecimal(arguments["delta_rub"].to_s)
      return old_amount - delta.abs if operation == "decrease"
      return old_amount + delta.abs if operation == "increase" || operation.blank?
    end
    return nil if arguments["amount_rub"].blank?

    amount = BigDecimal(arguments["amount_rub"].to_s)
    return old_amount + amount.abs if operation == "increase"
    return old_amount - amount.abs if operation == "decrease"

    amount
  end

  def source_label(source_type)
    self.class.source_label_for(source_type)
  end

  def object_query_from(context, arguments)
    query = arguments["object_query"].presence
    if query.blank? || pronoun_reference?(query)
      state = context.dig("conversation_memory", "working_state") || {}
      query = state["last_object_name"].presence || state["last_object_query"].presence || state["last_referenced_object"].presence
    end
    query
  end

  def pronoun_reference?(value)
    normalize_name(value).in?(%w[нему ней нем этом объекту позиции позиция])
  end

  def decision_summary(decision)
    {
      "id" => decision.id,
      "decision_type" => decision.decision_type,
      "status" => decision.status,
      "confidence" => decision.confidence&.to_s("F"),
      "selected_program_node_id" => decision.selected_program_node_id,
      "reason" => decision.reason,
      "validation_result" => decision.validation_result
    }
  end

  def money(value)
    format("%.2f", BigDecimal(value.to_s))
  rescue ArgumentError
    value.to_s
  end

  def filter_items_by_year(items, year)
    year = year.to_i
    return items if year.zero?

    items.select { |item| item.year.to_i == year }
  end

  def filter_items_by_object(items, query)
    query_tokens = normalize_name(query).split.map { |token| token.first(6) }.reject(&:blank?)
    return items if query_tokens.empty?

    items.select do |item|
      target = normalize_name([item.program_node&.name, item.new_value, item.source_reference&.fetch("object_name", nil)].compact.join(" "))
      query_tokens.any? { |token| target.include?(token) }
    end
  end

  def self.hierarchy_for_item(item)
    hierarchy = {}
    current = item.program_node
    while current
      hierarchy[current.node_type] ||= current.name
      current = current.parent
    end
    hierarchy
  end

  def hierarchy_for_item(item)
    self.class.hierarchy_for_item(item)
  end

  def change_set_from_arguments(arguments)
    id = arguments["change_set_id"].presence || arguments["change_project_id"].presence
    return nil if id.blank?

    scoped_change_sets.find_by(id: id)
  end

  def latest_change_set
    scoped_change_sets.order(updated_at: :desc).first
  end

  def latest_change_set_for_export
    scoped_change_sets
      .where.not(status: "rejected")
      .order(updated_at: :desc)
      .detect { |change_set| !summary_row_change_items?(change_set) }
  end

  def scoped_change_sets
    ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: @organization.id })
  end

  def normalize_name(value)
    value.to_s.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def funding_source_value(raw)
    FundingSourceCatalog.normalize(FundingLine.source_types.fetch(raw.to_s, raw.to_s), organization: @organization)
  end

  def funding_source_key(raw)
    FundingLine.source_types.key(funding_source_value(raw)) || raw.to_s
  end

  def pending_confirmation_scope(change_set)
    change_set.change_items
      .where(agent_resolution_status: "needs_clarification")
      .where.not(status: "rejected")
  end

  def actionable_items_count(change_set)
    change_set.change_items.where.not(status: "rejected").where.not(agent_resolution_status: "excluded").count
  end

  def safe_to_confirm?(item, change_set)
    return false if item.new_object?
    return false if BigDecimal(item.confidence.to_s.presence || "0") < BigDecimal(AgentSetting.for_organization!(@organization).match_confidence_threshold.to_s)
    return false if item.source_reference["source_conflict"].present?
    return false if Array(change_set.export_summary.dig("new_objects", "manual_item_ids")).map(&:to_i).include?(item.id)
    return false if item.source_reference["ocr_applied"].present?

    mode = item.source_reference["amount_mode"].presence || item.source_reference["original_amount_mode"].presence
    return false if mode.to_s.in?(%w[unknown transfer zeroing])
    return false if item.source_reference["transfer_pair"].present?

    true
  rescue ArgumentError
    false
  end

  def summary_row_change_items?(change_set)
    change_set.change_items
      .includes(:program_node)
      .where.not(status: "rejected")
      .where.not(agent_resolution_status: "excluded")
      .any? { |item| FinancialNodeClassifier.summary_row?(item.program_node) }
  end

  def discrepancy_items(arguments = {})
    change_set = latest_change_set
    return [] unless change_set

    items = change_set.change_items.includes(:program_node).where.not(status: "rejected").order(:year, :id).to_a
    items = filter_items_by_year(items, arguments["year"]) if arguments["year"].present?
    items = filter_items_by_object(items, arguments["object_query"]) if arguments["object_query"].present?
    items.first(12).map { |item| change_item_summary(item) }
  end

  def discrepancy_reason(item)
    return "конфликт Excel/PDF" if item.source_reference["source_conflict"].present?
    return "перенос между годами" if item.source_reference["transfer_pair"].present?
    return "обнуление финансирования" if item.source_reference["amount_mode"] == "zeroing"
    return "не удалось надежно определить тип изменения" if item.source_reference["amount_mode"] == "unknown"
    return "объект найден во внешнем источнике, но отсутствует в программе" if item.new_object?
    return item.agent_resolution_reason if item.agent_resolution_needs_clarification? && item.agent_resolution_reason.present?

    "сумма изменилась"
  end

  def autonomous_resolution
    change_set = latest_change_set
    return { "status" => "empty" } unless change_set

    resolution = AgentAutonomousResolver.new(change_set: change_set, user: @user).resolve!
    status = resolution.needs_clarification_count.positive? ? "needs_clarification" : "completed"
    {
      "status" => status,
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "resolved_count" => resolution.resolved_count,
      "excluded_count" => resolution.excluded_count,
      "needs_clarification_count" => resolution.needs_clarification_count,
      "pending_items" => change_set.reload.change_items.where(agent_resolution_status: "needs_clarification").order(:id).limit(10).map { |item| change_item_summary(item) }
    }
  end

  def apply_source_priority_to_change_set!(change_set, priority, resolved_conflicts)
    rejected_count = 0
    resolution = {
      "priority" => priority,
      "selected_by_user_id" => @user.id,
      "selected_at" => Time.current.iso8601,
      "resolved_conflicts" => resolved_conflicts.map { |conflict| conflict.slice("object_name", "year", "source_type") }
    }

    change_set.change_items.where.not(status: "rejected").find_each do |item|
      conflict = item.source_reference["source_conflict"]
      next if conflict.blank?

      document_type = item.source_reference["document_type"].presence || document_type_from_conflict(item, conflict)
      if document_type == priority
        source_reference = item.source_reference.except("source_conflict")
        item.update!(source_reference: source_reference)
      else
        item.update!(
          status: "rejected",
          requires_user_confirmation: false,
          user_confirmed: false,
          agent_resolution_status: "excluded",
          agent_resolution_reason: "Отклонено после выбора другого источника.",
          agent_resolved_at: Time.current,
          explanation: [item.explanation, "Отклонено после выбора другого источника."].compact.join(" ")
        )
        rejected_count += 1
      end
    end
    change_set.update!(export_summary: (change_set.export_summary || {}).merge("source_resolution" => resolution))
    change_set.refresh_summary!
    rejected_count
  end

  def document_type_from_conflict(item, conflict)
    source_document_id = item.source_reference["source_document_id"].to_i
    conflict.fetch("sources", {}).detect do |_type, payload|
      payload["source_document_id"].to_i == source_document_id
    end&.first
  end
end
