require "erb"

class ChangeSetReportBuilder
  include ERB::Util

  def initialize(change_set:, target_program_version:, export_summary:)
    @change_set = change_set
    @target_program_version = target_program_version
    @export_summary = export_summary
  end

  def html
    rows = @change_set.change_items.includes(:program_node).order(:id).map { |item| row_for(item) }
    <<~HTML
      <!doctype html>
      <html lang="ru">
      <head>
        <meta charset="utf-8">
        <title>Отчет об изменениях проекта №#{@change_set.id}</title>
        <style>
          body { font-family: Arial, sans-serif; color: #1f2933; margin: 32px; }
          h1 { font-size: 22px; margin-bottom: 8px; }
          p { margin: 6px 0; }
          table { border-collapse: collapse; width: 100%; margin-top: 20px; font-size: 12px; }
          th, td { border: 1px solid #cbd5e1; padding: 8px; vertical-align: top; }
          th { background: #eef2f7; text-align: left; }
          .money { text-align: right; white-space: nowrap; }
        </style>
      </head>
      <body>
        <h1>Отчет об изменениях проекта №#{@change_set.id}</h1>
        <p>Исходная версия: #{@change_set.program_version.version_number}</p>
        <p>Новая версия: #{@target_program_version.version_number}</p>
        <p>Статус: #{h(StatusPresenter.label(@change_set.status))}</p>
        <p>Обновлено значений в Word-документе: #{h(@export_summary.dig("docx_patch", "applied_count") || 0)}</p>
        <p>Требуют дополнительной проверки: #{h(@export_summary["manual_insert_required_count"] || 0)}</p>
        #{validation_block}
        <table>
          <thead>
            <tr>
              <th>Подпрограмма</th>
              <th>Основное мероприятие</th>
              <th>Мероприятие</th>
              <th>Объект</th>
              <th>Год</th>
              <th>Источник</th>
              <th>Сумма до</th>
              <th>Сумма после</th>
              <th>Разница</th>
              <th>Основание</th>
              <th>Статус</th>
            </tr>
          </thead>
          <tbody>
            #{rows.join("\n")}
          </tbody>
        </table>
      </body>
      </html>
    HTML
  end

  private

  def row_for(item)
    target_node = target_node_for(item)
    path = hierarchy_for(target_node)
    status = status_for(item)
    <<~HTML
      <tr>
        <td>#{h(path["subprogram"])}</td>
        <td>#{h(path["main_activity"])}</td>
        <td>#{h(path["activity"])}</td>
        <td>#{h(object_label_for(item, path))}</td>
        <td>#{h(item.year)}</td>
        <td>#{h(source_type_label(item.source_type))}</td>
        <td class="money">#{money(item.old_amount_rub)}</td>
        <td class="money">#{money(item.new_amount_rub)}</td>
        <td class="money">#{money(item.delta_rub)}</td>
        <td>#{h(reference_for(item))}</td>
        <td>#{h(status)}</td>
      </tr>
    HTML
  end

  def validation_block
    validation = @export_summary["post_export_validation"] || {}
    return "" if validation.blank?

    errors = Array(validation["errors"]).map do |error|
      "<li>#{h(error['message'] || error['code'])}</li>"
    end.join

    <<~HTML
      <h2>Проверка сформированного документа</h2>
      <p>Статус проверки: #{h(validation_status_label(validation["status"]))}</p>
      #{errors.present? ? "<ul>#{errors}</ul>" : ""}
    HTML
  end

  def hierarchy_for(node)
    result = {}
    current = node
    while current
      result[current.node_type] ||= current.name
      current = current.parent
    end
    result
  end

  def object_label_for(item, path)
    label = path["object"] || path["residual"]
    return label if valid_label?(label)

    if item.new_object?
      label = item.new_value.presence || item.source_reference&.dig("object_name")
      return label if valid_label?(label)
    elsif item.program_node&.node_type.to_s.in?(%w[object residual])
      label = item.program_node.name
      return label if valid_label?(label)
    end

    "Не определено"
  end

  def valid_label?(value)
    value.present? && !numeric_label?(value)
  end

  def numeric_label?(value)
    value.to_s.strip.match?(/\A[-+]?\d+(?:[.,]\d+)?\z/)
  end

  def status_for(item)
    return new_object_status_for(item) if item.new_object?
    return "Применено" if item.amount_update?

    StatusPresenter.label(item.change_type)
  end

  def new_object_status_for(item)
    manual_ids = Array(@export_summary.dig("new_objects", "manual_item_ids")).map(&:to_i)
    skipped_ids = Array(@export_summary.dig("docx_patch", "skipped_insertions")).flat_map { |entry| Array(entry["change_item_ids"]) }.map(&:to_i)
    return "Требуется дополнительная проверка перед вставкой" if manual_ids.include?(item.id) || skipped_ids.include?(item.id)

    "Вставлено в Word-документ"
  end

  def target_node_for(item)
    return item.program_node if item.program_node

    node_id = @export_summary.dig("new_objects", "target_node_ids_by_item_id", item.id.to_s)
    @target_program_version.program_nodes.find_by(id: node_id) if node_id.present?
  end

  def reference_for(item)
    reference = item.source_reference || {}
    parts = []
    parts << reference["filename"] if reference["filename"].present?
    parts << "Строка Excel #{reference['row_number']}" if reference["row_number"].present?
    parts << "Страница PDF #{reference['page_number']}" if reference["page_number"].present?
    parts.join("; ")
  end

  def source_type_label(source_type)
    FundingSourceCatalog.label(source_type, organization: @change_set.program_version.municipal_program.organization)
  end

  def validation_status_label(status)
    case status.to_s
    when "valid" then "документ прошел проверку"
    when "valid_with_warnings" then "документ прошел проверку с предупреждениями"
    when "invalid" then "документ не прошел проверку"
    else "проверка не завершена"
    end
  end

  def money(value)
    return "" if value.blank?

    h(format("%.2f", BigDecimal(value.to_s)).tr(".", ","))
  end
end
