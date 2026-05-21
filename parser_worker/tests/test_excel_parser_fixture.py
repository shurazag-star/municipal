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


def test_excel_parser_supports_budget_roster_plan_columns_and_type_codes(tmp_path):
    path = tmp_path / "budget_roster.xlsx"
    wb = Workbook()
    ws = wb.active
    ws.title = "Результат"
    ws.merge_cells("B8:M8")
    ws.merge_cells("N8:O8")
    ws.merge_cells("P8:Q8")
    ws.merge_cells("R8:S8")
    ws.merge_cells("T8:U8")
    ws.merge_cells("V8:X8")
    ws.merge_cells("Y8:Z8")
    ws.merge_cells("AA8:AB8")
    ws["B8"] = "Наименование"
    ws["N8"] = "ЦСР"
    ws["P8"] = "Тип средств"
    ws["R8"] = "Мероприятие"
    ws["T8"] = "Объект"
    ws["V8"] = "План на 2026 год"
    ws["Y8"] = "План на 2027 год"
    ws["AA8"] = "План на 2028год"
    ws["B9"] = 1
    ws["N9"] = 2
    ws["P9"] = 3
    ws["R9"] = 4
    ws["T9"] = 5
    ws["V9"] = 6
    ws["Y9"] = 7
    ws["AA9"] = 8

    ws["C10"] = 'Муниципальная программа "Развитие инженерной инфраструктуры"'
    ws["N10"] = "1000000000"
    ws["V10"] = 181000
    ws["Y10"] = 304000
    ws["AA10"] = 500000

    ws["F20"] = "Реконструкция ВЗУ Птицефабрика"
    ws["N20"] = "10102S4090"
    ws["P20"] = "900100"
    ws["R20"] = "101020100000000"
    ws["T20"] = "1000010939.5327942989"
    ws["V20"] = 17160000
    ws["Y20"] = 65780000
    ws["AA20"] = 0

    ws["F21"] = "Реконструкция ВЗУ Птицефабрика"
    ws["N21"] = "10102S4090"
    ws["P21"] = "900302"
    ws["R21"] = "101020100000000"
    ws["T21"] = "1000010939.5327942989"
    ws["V21"] = 300000
    ws["Y21"] = 400000
    ws["AA21"] = 500000

    ws["B30"] = "Итого:"
    ws["V30"] = 181000
    ws["Y30"] = 304000
    ws["AA30"] = 500000
    wb.save(path)

    parsed = parse_xlsx_finance_report(path)

    assert parsed.program_totals[2026] == Decimal("181000.00")
    assert parsed.final_totals[2028] == Decimal("500000.00")
    assert parsed.rows[0].funding == {}
    group = parsed.object_groups[0]
    assert group.rows[0].object_name == "Реконструкция ВЗУ Птицефабрика"
    assert group.funding[(2026, BudgetSource.LOCAL_BUDGET)] == Decimal("17160000.00")
    assert group.funding[(2026, BudgetSource.REGIONAL_BUDGET)] == Decimal("300000.00")
    assert group.funding[(2028, BudgetSource.REGIONAL_BUDGET)] == Decimal("500000.00")


def test_excel_parser_supports_relative_budget_roster_plan_years(tmp_path):
    path = tmp_path / "relative_budget_roster.xlsx"
    wb = Workbook()
    ws = wb.active
    ws.title = "Результат"
    ws["B2"] = "с 03.12.2025 по 07.05.2026"
    ws.merge_cells("B8:M8")
    ws.merge_cells("N8:O8")
    ws.merge_cells("P8:Q8")
    ws.merge_cells("R8:S8")
    ws.merge_cells("T8:U8")
    ws.merge_cells("V8:X8")
    ws.merge_cells("Y8:Z8")
    ws.merge_cells("AA8:AB8")
    ws["B8"] = "Наименование"
    ws["N8"] = "ЦСР"
    ws["P8"] = "Тип средств"
    ws["R8"] = "Мероприятие"
    ws["T8"] = "Объект"
    ws["V8"] = "План на 1 год"
    ws["Y8"] = "План на 2 год"
    ws["AA8"] = "План на 3 год"
    ws["B9"] = 1
    ws["N9"] = 2
    ws["P9"] = 3
    ws["R9"] = 4
    ws["T9"] = 5
    ws["V9"] = 6
    ws["Y9"] = 7
    ws["AA9"] = 8

    ws["C10"] = 'Муниципальная программа "Развитие инженерной инфраструктуры"'
    ws["N10"] = "1000000000"
    ws["V10"] = 181000
    ws["Y10"] = 304000
    ws["AA10"] = 500000

    ws["F20"] = "Реконструкция ВЗУ Птицефабрика"
    ws["N20"] = "10102S4090"
    ws["P20"] = "900100"
    ws["R20"] = "101020100000000"
    ws["T20"] = "1000010939.5327942989"
    ws["V20"] = 17160000
    ws["Y20"] = 65780000
    ws["AA20"] = 0

    ws["F21"] = "Реконструкция ВЗУ Птицефабрика"
    ws["N21"] = "10102S4090"
    ws["P21"] = "900302"
    ws["R21"] = "101020100000000"
    ws["T21"] = "1000010939.5327942989"
    ws["V21"] = 300000
    ws["Y21"] = 400000
    ws["AA21"] = 500000
    wb.save(path)

    parsed = parse_xlsx_finance_report(path)

    assert parsed.program_totals[2026] == Decimal("181000.00")
    group = parsed.object_groups[0]
    assert group.funding[(2026, BudgetSource.LOCAL_BUDGET)] == Decimal("17160000.00")
    assert group.funding[(2027, BudgetSource.LOCAL_BUDGET)] == Decimal("65780000.00")
    assert group.funding[(2028, BudgetSource.REGIONAL_BUDGET)] == Decimal("500000.00")
