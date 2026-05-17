module DashboardHelper
  def document_status_class(status)
    case status
    when "parsed" then "status-ok"
    when "failed" then "status-danger"
    else "status-warn"
    end
  end

  def document_summary(document)
    payload = document.parsed_payload || {}
    return "Файл не прикреплен" unless document.file_attachment.attached?
    return payload["message"] if document.status == "failed" && payload["message"].present?

    case document.document_type
    when "docx_program"
      totals = payload["passport_totals_by_year"] || {}
      totals.any? ? "Паспортные итоги: #{totals.map { |year, amount| "#{year}: #{amount}" }.join(", ")}" : "Ожидает разбора"
    when "xlsx_finance"
      totals = payload["program_totals"] || {}
      totals.any? ? "Итоги Excel: #{totals.map { |year, amount| "#{year}: #{amount}" }.join(", ")}" : "Ожидает разбора"
    when "pdf_procedure"
      rules = payload["rules"] || []
      rules.any? ? "Правил извлечено: #{rules.size}" : "Ожидает разбора"
    else
      "Ожидает разбора"
    end
  end

  def agent_state_label(latest_documents_by_type, reconciliations)
    docx = latest_documents_by_type["docx_program"]&.status == "parsed"
    xlsx = latest_documents_by_type["xlsx_finance"]&.status == "parsed"
    pdf = latest_documents_by_type["pdf_procedure"]&.status == "parsed"

    if reconciliations.any?
      "сверка готова"
    elsif docx && xlsx
      "документы разобраны, сверка формируется"
    elsif docx || xlsx || pdf
      "часть документов разобрана"
    else
      "ожидает документы"
    end
  end
end
