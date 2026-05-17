from decimal import Decimal

from municipal_agent.budget_sources import BudgetSource
from municipal_agent.excel_parser import ExcelFinanceRow, group_excel_object_rows
from municipal_agent.row_classification import ExcelRowType


def test_groups_cherusti_duplicate_object_rows_by_sources():
    rows = [
        ExcelFinanceRow(
            row_number=21,
            row_type=ExcelRowType.OBJECT_LEAF_ROW,
            parent_activity_code="01.01",
            object_code="CHERUSTI",
            object_name="ВЗУ Черусти",
            funding={(2026, BudgetSource.MOSCOW_OBLAST_BUDGET): Decimal("78330390.00")},
        ),
        ExcelFinanceRow(
            row_number=23,
            row_type=ExcelRowType.OBJECT_LEAF_ROW,
            parent_activity_code="01.01",
            object_code="CHERUSTI",
            object_name="ВЗУ Черусти",
            funding={(2026, BudgetSource.LOCAL_BUDGET): Decimal("12224990.00")},
        ),
    ]

    grouped = group_excel_object_rows(rows)

    assert len(grouped) == 1
    group = grouped[0]
    assert group.total_by_year()[2026] == Decimal("90555380.00")
    assert group.funding[(2026, BudgetSource.MOSCOW_OBLAST_BUDGET)] == Decimal("78330390.00")
    assert group.funding[(2026, BudgetSource.LOCAL_BUDGET)] == Decimal("12224990.00")


def test_groups_tugolessky_bor_rows_by_year_and_source():
    rows = [
        ExcelFinanceRow(31, ExcelRowType.OBJECT_LEAF_ROW, "01.02", "TUG", "ВЗУ Туголесский Бор", {(2027, BudgetSource.LOCAL_BUDGET): Decimal("11245500.00"), (2028, BudgetSource.LOCAL_BUDGET): Decimal("9639000.00")}),
        ExcelFinanceRow(32, ExcelRowType.OBJECT_LEAF_ROW, "01.02", "TUG", "ВЗУ Туголесский Бор", {(2027, BudgetSource.MOSCOW_OBLAST_BUDGET): Decimal("48254500.00"), (2028, BudgetSource.MOSCOW_OBLAST_BUDGET): Decimal("41361000.00")}),
    ]

    group = group_excel_object_rows(rows)[0]

    assert group.total_by_year()[2027] == Decimal("59500000.00")
    assert group.total_by_year()[2028] == Decimal("51000000.00")


def test_keeps_unassigned_residual_as_service_object_group():
    rows = [
        ExcelFinanceRow(
            row_number=44,
            row_type=ExcelRowType.UNASSIGNED_RESIDUAL_ROW,
            parent_activity_code="02.03",
            object_code="0000000000.0000000000",
            object_name="",
            funding={(2026, BudgetSource.LOCAL_BUDGET): Decimal("1000.00")},
        )
    ]

    group = group_excel_object_rows(rows)[0]

    assert group.group_key.startswith("UNASSIGNED_RESIDUAL::02.03::44")
    assert group.status == "UNASSIGNED_RESIDUAL"
    assert group.total_by_year()[2026] == Decimal("1000.00")


def test_preserves_explicit_zero_object_group():
    rows = [
        ExcelFinanceRow(
            row_number=61,
            row_type=ExcelRowType.OBJECT_LEAF_ROW,
            parent_activity_code="01.01",
            object_code="1000000000.0000000001",
            object_name="Нулевой объект",
            funding={},
            explicit_zero_target=True,
        )
    ]

    group = group_excel_object_rows(rows)[0]

    assert group.status == "GROUPED_OBJECT"
    assert group.funding == {}
    assert group.explicit_zero_target is True
