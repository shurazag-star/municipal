class IndependentVerifierAgent
  VALID_EXPORT_STATUSES = %w[valid valid_with_warnings].freeze

  BLOCKING_REASON_BY_CHECK = {
    "нет нерешенных строк изменений" => "есть нерешенные строки изменений",
    "семантические решения прошли независимую проверку" => "семантическое сопоставление содержит неподтвержденные или противоречивые решения",
    "внешняя целевая модель допустима" => "внешняя целевая модель не прошла независимую проверку",
    "PDF-журнал допустим" => "PDF-журнал частичных правок не прошел независимую проверку",
    "PDF-операции применены после экспорта" => "PDF-операции не подтверждены после экспорта DOCX",
    "повторная проверка DOCX допустима" => "повторная проверка DOCX не прошла",
    "нет применяемых изменений на итоговых строках" => "часть изменений привязана к итоговым строкам, а не к объектам",
    "нет ручных вставок после patcher" => "после patcher остались ручные вставки",
    "нет числовых названий объектов" => "в дереве программы есть числовые названия объектов",
    "артефакты сформированы" => "не сформированы все итоговые артефакты"
  }.freeze

  def initialize(change_set:, target_program_version:, export_summary:)
    @change_set = change_set
    @target_program_version = target_program_version
    @export_summary = export_summary || {}
  end

  def verify
    {
      "status" => blocking_reasons.empty? ? "passed" : "failed",
      "checks" => checks,
      "blocking_reasons" => blocking_reasons,
      "evidence" => evidence
    }
  end

  private

  def checks
    [
      check("нет нерешенных строк изменений", unresolved_change_items_count.zero?),
      check("семантические решения прошли независимую проверку", semantic_decisions_valid?),
      check("внешняя целевая модель допустима", external_target_model_ready?),
      check("PDF-журнал допустим", pdf_patch_ledger_ready?),
      check("PDF-операции применены после экспорта", external_patch_validation_ready?),
      check("повторная проверка DOCX допустима", VALID_EXPORT_STATUSES.include?(post_export_status)),
      check("нет применяемых изменений на итоговых строках", summary_row_change_items.empty?),
      check("нет ручных вставок после patcher", @export_summary["manual_insert_required_count"].to_i.zero?),
      check("нет числовых названий объектов", numeric_object_names.empty?),
      check("артефакты сформированы", artifacts_attached?)
    ]
  end

  def blocking_reasons
    @blocking_reasons ||= checks.filter_map do |item|
      item["passed"] ? nil : BLOCKING_REASON_BY_CHECK.fetch(item["label"], item["label"])
    end
  end

  def evidence
    {
      "unresolved_change_items_count" => unresolved_change_items_count,
      "semantic_decisions_count" => semantic_decisions.count,
      "semantic_decision_failures" => semantic_decision_failures.first(10),
      "post_export_status" => post_export_status,
      "manual_insert_required_count" => @export_summary["manual_insert_required_count"].to_i,
      "numeric_object_names" => numeric_object_names.first(10),
      "summary_row_change_item_ids" => summary_row_change_items.map(&:id).first(10),
      "external_target_model_status" => external_target_model&.fetch("status", nil),
      "pdf_patch_ledger_status" => pdf_patch_ledger&.fetch("status", nil),
      "external_patch_validation_status" => external_patch_validation&.fetch("status", nil),
      "generated_docx_attached" => @change_set.generated_docx_attachment.attached?,
      "change_report_attached" => @change_set.change_report_attachment.attached?
    }.compact
  end

  def check(label, passed)
    { "label" => label, "passed" => !!passed }
  end

  def unresolved_change_items_count
    @unresolved_change_items_count ||= @change_set.change_items
      .where(agent_resolution_status: %w[unresolved needs_clarification])
      .where.not(status: "rejected")
      .count
  end

  def external_target_model_ready?
    return true if external_target_model.blank?

    external_target_model["status"] != "blocked" && Array(external_target_model["blocking_reasons"]).empty?
  end

  def semantic_decisions_valid?
    semantic_decision_failures.empty?
  end

  def semantic_decision_failures
    @semantic_decision_failures ||= semantic_decisions.filter_map do |decision|
      next if decision.status_accepted? && decision.validation_result.to_h["passed"] != false && selected_candidate_valid?(decision)

      {
        "agent_match_decision_id" => decision.id,
        "status" => decision.status,
        "decision_type" => decision.decision_type,
        "reason" => decision.reason,
        "validation_result" => decision.validation_result
      }
    end
  end

  def semantic_decisions
    @semantic_decisions ||= AgentMatchDecision
      .where(analysis_session: @change_set.analysis_session)
      .where(status: "accepted")
      .to_a
  end

  def selected_candidate_valid?(decision)
    return true unless decision.selected_program_node_id

    Array(decision.candidate_snapshot).any? do |candidate|
      candidate["program_node_id"].to_i == decision.selected_program_node_id.to_i
    end
  end

  def pdf_patch_ledger_ready?
    return true unless pdf_patch_mode?
    return false if pdf_patch_ledger.blank?

    pdf_patch_ledger["status"] == "ready"
  end

  def external_patch_validation_ready?
    return true unless pdf_patch_mode?
    return false if external_patch_validation.blank?

    external_patch_validation["status"] == "passed"
  end

  def external_target_model
    @change_set.analysis_session&.summary&.fetch("external_target_model", nil)
  end

  def pdf_patch_ledger
    @export_summary["external_patch_ledger"].presence ||
      @change_set.analysis_session&.summary&.fetch("pdf_patch_ledger", nil)
  end

  def external_patch_validation
    @export_summary["external_patch_validation"]
  end

  def pdf_patch_mode?
    @change_set.analysis_session&.effective_source_mode == "pdf_patch"
  end

  def post_export_status
    @export_summary.dig("post_export_validation", "status").to_s
  end

  def numeric_object_names
    @numeric_object_names ||= @target_program_version.program_nodes
      .where(node_type: %w[object residual])
      .pluck(:name)
      .select { |name| numeric_label?(name) }
  end

  def summary_row_change_items
    @summary_row_change_items ||= @change_set.change_items
      .includes(:program_node)
      .where.not(status: "rejected")
      .where.not(agent_resolution_status: "excluded")
      .select { |item| FinancialNodeClassifier.summary_row?(item.program_node) }
  end

  def numeric_label?(value)
    normalized = value.to_s.tr(" ", "").tr(",", ".")
    normalized.match?(/\A[\d.]+\z/) && normalized.count("0-9") >= 5
  end

  def artifacts_attached?
    @change_set.generated_docx_attachment.attached? && @change_set.change_report_attachment.attached?
  end
end
