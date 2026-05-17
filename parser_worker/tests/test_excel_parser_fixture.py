from decimal import Decimal

from openpyxl import Workbook

from municipal_agent.budget_sources import BudgetSource
from municipal_agent.excel_parser import parse_xlsx_finance_report
from municipal_agent.row_classification import ExcelRowType


def test_excel_parser_finds_result_sheet_totals_duplicates_and_residual(tmp_path):
    path = tmp_path / "finance.xlsx"
    wb = Workbook()
    ws = wb.active
    ws.title = "Результат"
    ws.append(
        [
            "Наименование",
            "Код целевой программы",
            "Код мероприятия",
            "Код объекта",
            "Наименование объекта по адресному перечню",
            "2026 всего",
            "2026 бюджет субъекта РФ",
            "2026 местный бюджет",
            "2027 всего",
            "2027 бюджет субъекта РФ",
            "2027 местный бюджет",
            "2028 всего",
            "2028 бюджет субъекта РФ",
            "2028 местный бюджет",
        ]
    )
    ws.append(["Муниципальная программа Развитие ЖКХ", "01", "", "", "", 2253220255.91, 0, 0, 1776791196.12, 0, 0, 780689180, 0, 0])
    ws.append(["", "", "01.01", "CHERUSTI", "ВЗУ Черусти", 90555380, 78330390, 12224990, 0, 0, 0, 0, 0, 0])
    ws.append(["", "", "02.03", "0000000000.0000000000", "", 1000, 0, 1000, 0, 0, 0, 0, 0, 0])
    ws.append(["Итого:", "", "", "", "", 2253220255.91, 0, 0, 1776791196.12, 0, 0, 780689180, 0, 0])
    wb.save(path)

    parsed = parse_xlsx_finance_report(path)

    assert parsed.sheet_name == "Результат"
    assert parsed.program_totals[2026] == Decimal("2253220255.91")
    assert sum(1 for row in parsed.rows if row.row_type == ExcelRowType.FINAL_TOTAL_ROW) == 1
    assert parsed.total_without_double_count()[2026] == Decimal("2253220255.91")
    assert parsed.object_groups[0].total_by_year()[2026] == Decimal("90555380.00")
    assert parsed.object_groups[1].status == "UNASSIGNED_RESIDUAL"
    assert parsed.object_groups[1].funding[(2026, BudgetSource.LOCAL_BUDGET)] == Decimal("1000.00")

