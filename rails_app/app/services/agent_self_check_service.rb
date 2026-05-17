require "set"

class AgentSelfCheckService
  VALID_EXPORT_STATUSES = %w[valid valid_with_warnings].freeze
  BLOCKING_REASON_BY_CHECK = {
    "нет строк, которые требуют уточнения" => "есть строки, которые агент не смог надежно разобрать",
    "нет нерешенных конфликтов Excel/PDF" => "есть нерешенные конфликты Excel/PDF",
    "нет новых объектов для дополнительной проверки" => "есть новые объекты для дополнительной проверки",
    "покрытие Excel-цели достаточно" => "Excel-цель не покрывает объекты программы достаточно надежно",
    "профиль DOCX-программы распознан надежно" => "структура DOCX-программы распознана недостаточно надежно",
    "PDF-журнал частичных правок готов" => "PDF-журнал частичных правок не готов к применению",
    "PDF-операции подтверждены после экспорта" => "PDF-операции не подтверждены после экспорта DOCX",
    "нет изменений, привязанных к итоговым строкам" => "есть изменения, ошибочно привязанные к итоговым строкам",
    "итоговый Word-документ прошел повторную проверку" => "итоговый Word-документ не прошел повторную проверку",
    "итоговый Word-документ прикреплен" => "итоговый Word-документ не прикреплен",
    "отчет об изменениях прикреплен" => "отчет об изменениях не прикреплен",
    "визуальная проверка Word-документа пройдена" => "визуальная проверка Word-документа не пройдена"
  }.freeze

  def initialize(change_set:, export_summary: nil, persist: true, reload_record: true)
    @change_set = change_set
    @export_summary = export_summary
    @persist = persist
    @reload_record = reload_record
  end

  def call
    @change_set.reload if @reload_record
    result = {
      "status" => blocking_reasons.empty? ? "passed" : "failed",
      "checks" => checks,
      "blocking_reasons" => blocking_reasons
    }
    persist_result(result) if @persist
    result
  end

  private

  def checks
    [
      check("нет строк, которые требуют уточнения", unresolved_count.zero?),
      check("нет нерешенных конфликтов Excel/PDF", source_conflicts.empty?),
      check("нет новых объектов для дополнительной проверки", manual_insert_required_count.zero?),
      check("покрытие Excel-цели достаточно", external_target_model_ready?),
      check("профиль DOCX-программы распознан надежно", document_profile_ready?),
      check("PDF-журнал частичных правок готов", pdf_patch_ledger_ready?),
      check("PDF-операции подтверждены после экспорта", external_patch_validation_ready?),
      check("нет изменений, привязанных к итоговым строкам", summary_row_change_items.empty?),
      check("итоговый Word-документ прошел повторную проверку", VALID_EXPORT_STATUSES.include?(post_export_status)),
      check("итоговый Word-документ прикреплен", @change_set.generated_docx_attachment.attached?),
      check("отчет об изменениях прикреплен", @change_set.change_report_attachment.attached?),
      check("визуальная проверка Word-документа пройдена", visual_render_passed?)
    ]
  end

  def blocking_reasons
    @blocking_reasons ||= checks.filter_map do |item|
      item["passed"] ? nil : BLOCKING_REASON_BY_CHECK.fetch(item["label"], item["label"])
    end
  end

  def check(label, passed)
    { "label" => label, "passed" => !!passed }
  end

  def unresolved_count
    @change_set.change_items.where(agent_resolution_status: %w[unresolved needs_clarification]).where.not(status: "rejected").count
  end

  def manual_insert_required_count
    export_summary["manual_insert_required_count"].to_i
  end

  def source_conflicts
    conflicts = Array(export_summary["source_conflicts"]).presence ||
      Array(@change_set.analysis_session&.summary&.fetch("source_conflicts", nil))
    resolved_keys = resolved_conflicts.map { |conflict| conflict_key(conflict) }.to_set
    conflicts.reject { |conflict| resolved_keys.include?(conflict_key(conflict)) }
  end

  def external_target_model_ready?
    model = @change_set.analysis_session&.summary&.fetch("external_target_model", nil)
    return true if model.blank?

    model["status"] != "blocked" && Array(model["blocking_reasons"]).empty?
  end

  def document_profile_ready?
    status = @change_set.program_version.import_summary.to_h["municipal_document_profile_status"].to_s
    return true if status.blank?

    status == "active"
  end

  def pdf_patch_ledger_ready?
    return true unless pdf_patch_mode?

    ledger = export_summary["external_patch_ledger"].presence ||
      @change_set.analysis_session&.summary&.fetch("pdf_patch_ledger", nil)
    return false if ledger.blank?

    ledger["status"] == "ready"
  end

  def external_patch_validation_ready?
    return true unless pdf_patch_mode?

    validation = export_summary["external_patch_validation"]
    return false if validation.blank?

    validation["status"] == "passed"
  end

  def summary_row_change_items
    @summary_row_change_items ||= @change_set.change_items
      .includes(:program_node)
      .where.not(status: "rejected")
      .where.not(agent_resolution_status: "excluded")
      .select { |item| FinancialNodeClassifier.summary_row?(item.program_node) }
  end

  def pdf_patch_mode?
    @change_set.analysis_session&.effective_source_mode == "pdf_patch"
  end

  def resolved_conflicts
    resolution = export_summary["source_resolution"].presence ||
      @change_set.analysis_session&.summary&.fetch("source_resolution", nil)
    Array(resolution&.fetch("resolved_conflicts", nil))
  end

  def conflict_key(conflict)
    [
      conflict["object_name"].to_s.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip,
      conflict["year"].to_i,
      conflict["source_type"].to_s
    ]
  end

  def post_export_status
    export_summary.dig("post_export_validation", "status").to_s
  end

  def visual_render_passed?
    visual_status = export_summary.dig("post_export_validation", "visual_render", "status")
    visual_status.blank? || visual_status == "valid"
  end

  def persist_result(result)
    @change_set.update!(
      export_summary: export_summary.merge("agent_self_check" => result)
    )
  end

  def export_summary
    @export_summary || @change_set.export_summary || {}
  end
end
