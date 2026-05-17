from __future__ import annotations

from dataclasses import asdict
from decimal import Decimal
from html import escape
import json
from pathlib import Path
from typing import Dict

from openpyxl import Workbook

from .docx_parser import parse_docx_program
from .excel_parser import parse_xlsx_finance_report
from .procedure_pdf_parser import parse_pdf_procedure
from .reconcile import compare_program_totals


def generate_reconciliation_artifacts(
    docx_path: str | Path,
    xlsx_path: str | Path,
    pdf_path: str | Path,
    output_dir: str | Path,
) -> Dict[str, Path]:
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)

    docx = parse_docx_program(docx_path)
    excel = parse_xlsx_finance_report(xlsx_path)
    procedure = parse_pdf_procedure(pdf_path)
    diffs = compare_program_totals(docx.passport_totals_by_year, excel.program_totals)

    mapping_path = output / "mapping_report.json"
    html_path = output / "control_sums_report.html"
    xlsx_report_path = output / "change_report.xlsx"

    payload = {
        "docx": {
            "subprograms": [asdict(item) for item in docx.subprograms],
            "passport_totals_by_year": {str(year): str(amount) for year, amount in docx.passport_totals_by_year.items()},
        },
        "excel": {
            "sheet_name": excel.sheet_name,
            "program_totals": {str(year): str(amount) for year, amount in excel.program_totals.items()},
            "final_totals": {str(year): str(amount) for year, amount in excel.final_totals.items()},
            "object_group_count": len(excel.object_groups),
            "residual_group_count": sum(1 for group in excel.object_groups if group.status == "UNASSIGNED_RESIDUAL"),
            "known_duplicate_groups": _known_duplicate_groups(excel.object_groups),
        },
        "procedure_pdf": {
            "page_count": procedure.page_count,
            "text_char_count": procedure.text_char_count,
            "rules": procedure.rules,
        },
        "reconciliation": [
            {
                "status": diff.status,
                "year": diff.year,
                "docx_amount_rub": str(diff.docx_amount_rub),
                "external_amount_rub": str(diff.external_amount_rub),
                "delta_rub": str(diff.delta_rub),
            }
            for diff in diffs
        ],
    }
    mapping_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    html_path.write_text(_render_control_sums_html(payload), encoding="utf-8")
    _write_change_report_xlsx(xlsx_report_path, diffs)

    return {
        "mapping_report_json": mapping_path,
        "control_sums_report_html": html_path,
        "change_report_xlsx": xlsx_report_path,
    }


def _known_duplicate_groups(groups) -> list[dict]:
    result = []
    for group in groups:
        name = group.rows[0].object_name if group.rows else ""
        if "Черусти" in name or "Туголесский" in name or group.status == "UNASSIGNED_RESIDUAL":
            result.append(
                {
                    "group_key": group.group_key,
                    "name": _display_group_name(name, group.status),
                    "status": group.status,
                    "rows": [row.row_number for row in group.rows],
                    "total_by_year": {str(year): str(amount) for year, amount in group.total_by_year().items()},
                }
            )
    return result


def _display_group_name(name: str, status: str) -> str:
    if status == "UNASSIGNED_RESIDUAL":
        return "Не распределено по объектам / служебный остаток"
    if "Черусти" in name:
        return "ВЗУ Черусти"
    if "Туголесский" in name:
        return "ВЗУ Туголесский Бор"
    return name


def _render_control_sums_html(payload: dict) -> str:
    diff_rows = "\n".join(
        "<tr>"
        f"<td>{item['year']}</td>"
        f"<td>{escape(item['status'])}</td>"
        f"<td>{item['docx_amount_rub']}</td>"
        f"<td>{item['external_amount_rub']}</td>"
        f"<td>{item['delta_rub']}</td>"
        "</tr>"
        for item in payload["reconciliation"]
    )
    duplicate_rows = "\n".join(
        "<tr>"
        f"<td>{escape(item['name'])}</td>"
        f"<td>{escape(item['status'])}</td>"
        f"<td>{escape(', '.join(str(row) for row in item['rows']))}</td>"
        f"<td>{escape(json.dumps(item['total_by_year'], ensure_ascii=False))}</td>"
        "</tr>"
        for item in payload["excel"]["known_duplicate_groups"]
    )
    rules = "\n".join(f"<li>{escape(rule)}</li>" for rule in payload["procedure_pdf"]["rules"])
    return f"""<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <title>Отчет контрольных сумм</title>
  <style>
    body {{ font-family: Arial, sans-serif; margin: 32px; color: #1f2933; }}
    table {{ border-collapse: collapse; width: 100%; margin: 16px 0 28px; }}
    th, td {{ border: 1px solid #cbd2d9; padding: 8px; text-align: left; vertical-align: top; }}
    th {{ background: #f1f5f9; }}
  </style>
</head>
<body>
  <h1>Отчет контрольных сумм</h1>
  <h2>Расхождения DOCX / Excel</h2>
  <table>
    <thead><tr><th>Год</th><th>Статус</th><th>DOCX, руб.</th><th>Excel, руб.</th><th>Разница, руб.</th></tr></thead>
    <tbody>{diff_rows}</tbody>
  </table>
  <h2>Дубли и служебные строки</h2>
  <table>
    <thead><tr><th>Объект</th><th>Статус</th><th>Строки Excel</th><th>Итоги по годам</th></tr></thead>
    <tbody>{duplicate_rows}</tbody>
  </table>
  <h2>Правила из постановления</h2>
  <ul>{rules}</ul>
</body>
</html>
"""


def _write_change_report_xlsx(path: Path, diffs) -> None:
    workbook = Workbook()
    worksheet = workbook.active
    worksheet.title = "Расхождения"
    worksheet.append(["Год", "Статус", "DOCX, руб.", "Excel, руб.", "Разница, руб."])
    for diff in diffs:
        worksheet.append(
            [
                diff.year,
                diff.status,
                float(diff.docx_amount_rub),
                float(diff.external_amount_rub),
                float(diff.delta_rub),
            ]
        )
    workbook.save(path)


def _json_default(value):
    if isinstance(value, Decimal):
        return str(value)
    raise TypeError(f"Cannot serialize {value!r}")
