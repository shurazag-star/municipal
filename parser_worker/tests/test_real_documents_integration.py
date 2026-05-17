from decimal import Decimal
from pathlib import Path

import pytest

from municipal_agent.budget_sources import BudgetSource
from municipal_agent.docx_parser import parse_docx_program
from municipal_agent.excel_parser import parse_xlsx_finance_report
from municipal_agent.procedure_pdf_parser import parse_pdf_procedure
from municipal_agent.reconcile import compare_program_totals
from municipal_agent.row_classification import ExcelRowType


ROOT = Path(__file__).resolve().parents[2]
SAMPLES = ROOT / "sample_documents"
DOCX = SAMPLES / "проект изменений МП_март_2026 (10).docx"
XLSX = SAMPLES / "Отчет_о_финансировании_мероприятий_целевых_программ+_Расширенный.xlsx"
PDF = SAMPLES / "2. № 2291 от 16.10.2025.pdf"
pytestmark = pytest.mark.skipif(
    not DOCX.exists() or not XLSX.exists() or not PDF.exists(),
    reason="real sample documents are not committed to the deploy repository",
)


def test_real_docx_extracts_passport_and_8_subprograms():
    parsed = parse_docx_program(DOCX)

    assert len(parsed.subprograms) == 8
    assert [item.name for item in parsed.subprograms] == [
        "Чистая вода",
        "Системы водоотведения",
        "Объекты теплоснабжения, инженерные коммуникации",
        "Обращение с отходами",
        "Энергосбережение и повышение энергетической эффективности",
        "Развитие газификации, топливнозаправочного комплекса и электроэнергетики",
        "Обеспечивающая подпрограмма",
        "Реализация полномочий в сфере жилищно-коммунального хозяйства",
    ]
    assert parsed.passport_amounts[(2026, BudgetSource.MOSCOW_OBLAST_BUDGET)] == Decimal("1858904680.00")
    assert parsed.passport_amounts[(2026, BudgetSource.LOCAL_BUDGET)] == Decimal("437197280.00")
    assert parsed.passport_totals_by_year[2026] == Decimal("2296101960.00")
    assert parsed.passport_totals_by_year[2027] == Decimal("1866791200.00")
    assert parsed.passport_totals_by_year[2028] == Decimal("690689180.00")
    assert parsed.passport_total_cell_coordinates[2026]["table_index"] is not None
    assert parsed.passport_total_cell_coordinates[2026]["cell_index"] is not None
    assert parsed.passport_source_cell_coordinates[(2026, BudgetSource.LOCAL_BUDGET)]["cell_index"] is not None


def test_real_docx_extracts_full_tree_nodes_and_funding_lines():
    parsed = parse_docx_program(DOCX)

    assert len(parsed.nodes) > 100
    assert len(parsed.funding_lines) > 100
    assert {"program", "subprogram", "main_activity", "activity", "object", "result"}.issubset({node.node_type for node in parsed.nodes})

    cherusti = next(
        node
        for node in parsed.nodes
        if node.node_type == "object" and "Черусти" in node.name and "котельной" in node.name
    )
    assert cherusti.source_table_index == 6
    assert cherusti.source_row_index == 61
    assert cherusti.parent_stable_key

    lines = [line for line in parsed.funding_lines if line.node_stable_key == cherusti.stable_key]
    assert {line.source_type for line in lines} >= {BudgetSource.MOSCOW_OBLAST_BUDGET, BudgetSource.LOCAL_BUDGET}
    assert any(line.year == 2026 and line.amount_rub == Decimal("2302960.00") for line in lines)
    assert all(line.source_cell_index is not None for line in lines)
    assert all(line.total_cell_index is not None for line in lines)


def test_real_excel_extracts_totals_without_double_counting_final_total():
    parsed = parse_xlsx_finance_report(XLSX)

    assert parsed.sheet_name == "Результат"
    assert parsed.program_totals[2026] == Decimal("2253220255.91")
    assert parsed.program_totals[2027] == Decimal("1776791196.12")
    assert parsed.program_totals[2028] == Decimal("780689180.00")
    assert parsed.final_totals == parsed.program_totals
    assert sum(1 for row in parsed.rows if row.row_type == ExcelRowType.FINAL_TOTAL_ROW) == 1
    assert parsed.total_without_double_count() == parsed.program_totals


def test_real_excel_groups_known_duplicates_and_residuals():
    parsed = parse_xlsx_finance_report(XLSX)

    cherusti = next(group for group in parsed.object_groups if "1000004207.1000005123" in group.group_key)
    assert cherusti.total_by_year()[2026] == Decimal("90555380.00")
    assert cherusti.funding[(2026, BudgetSource.MOSCOW_OBLAST_BUDGET)] == Decimal("78330390.00")
    assert cherusti.funding[(2026, BudgetSource.LOCAL_BUDGET)] == Decimal("12224990.00")

    tugolessky = next(group for group in parsed.object_groups if "1000010247.5327942181" in group.group_key)
    assert tugolessky.total_by_year()[2027] == Decimal("59500000.00")
    assert tugolessky.total_by_year()[2028] == Decimal("51000000.00")
    assert tugolessky.funding[(2027, BudgetSource.LOCAL_BUDGET)] == Decimal("11245500.00")
    assert tugolessky.funding[(2028, BudgetSource.LOCAL_BUDGET)] == Decimal("9639000.00")

    residuals = [group for group in parsed.object_groups if group.status == "UNASSIGNED_RESIDUAL"]
    assert residuals
    assert any("UNASSIGNED_RESIDUAL::101021300000000::14" == group.group_key for group in residuals)


def test_real_docx_excel_passport_reconciliation_detects_known_diffs():
    docx = parse_docx_program(DOCX)
    excel = parse_xlsx_finance_report(XLSX)

    diffs = compare_program_totals(docx.passport_totals_by_year, excel.program_totals)

    assert [diff.year for diff in diffs] == [2026, 2027, 2028]
    assert [diff.delta_rub for diff in diffs] == [
        Decimal("-42881704.09"),
        Decimal("-90000003.88"),
        Decimal("90000000.00"),
    ]


def test_real_pdf_procedure_extracts_text_and_core_rules():
    parsed = parse_pdf_procedure(PDF)

    assert parsed.page_count == 55
    assert parsed.text_char_count > 10000
    assert "муницип" in parsed.normalized_text
    assert "5 рабочих дней" in parsed.normalized_text
    assert "контрольно-счетной палат" in parsed.normalized_text
    assert "Муниципальная программа является документом стратегического планирования" in parsed.rules
    assert "Проект изменений не требует согласования с Контрольно-счетной палатой" in parsed.rules


def test_real_pdf_procedure_returns_pages_and_knowledge_chunks():
    parsed = parse_pdf_procedure(PDF)

    assert parsed.pages[0]["page_number"] == 1
    assert parsed.pages[0]["normalized_text"]
    chunk_types = {chunk["chunk_type"] for chunk in parsed.chunks}
    assert {
        "procedure_general",
        "program_structure",
        "indicators_and_results",
        "change_procedure",
        "approval_terms",
        "forms",
        "reporting",
    }.issubset(chunk_types)
    assert all(chunk["content"] for chunk in parsed.chunks)
