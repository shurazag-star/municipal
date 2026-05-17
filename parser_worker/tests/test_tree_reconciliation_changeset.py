from decimal import Decimal

from municipal_agent.budget_sources import BudgetSource
from municipal_agent.changeset import ChangeItem, ChangeSet, apply_changeset
from municipal_agent.program_tree import FundingLine, ProgramNode, NodeType, recalculate_tree
from municipal_agent.reconcile import compare_program_totals


def test_detects_program_total_diffs_between_docx_passport_and_excel():
    docx = {
        2026: Decimal("2296101960.00"),
        2027: Decimal("1866791200.00"),
        2028: Decimal("690689180.00"),
    }
    excel = {
        2026: Decimal("2253220255.91"),
        2027: Decimal("1776791196.12"),
        2028: Decimal("780689180.00"),
    }

    diffs = compare_program_totals(docx, excel)

    assert [d.status for d in diffs] == ["PROGRAM_TOTAL_DIFF", "PROGRAM_TOTAL_DIFF", "PROGRAM_TOTAL_DIFF"]
    assert diffs[0].delta_rub == Decimal("-42881704.09")
    assert diffs[1].delta_rub == Decimal("-90000003.88")
    assert diffs[2].delta_rub == Decimal("90000000.00")


def test_recalculates_tree_bottom_up_after_object_change():
    root = ProgramNode("program", NodeType.PROGRAM, "Программа")
    sub = ProgramNode("sub1", NodeType.SUBPROGRAM, "Подпрограмма 1", parent_id=root.id)
    activity = ProgramNode("act1", NodeType.ACTIVITY, "Мероприятие", parent_id=sub.id)
    obj = ProgramNode("obj1", NodeType.OBJECT, "Объект", parent_id=activity.id)
    obj.funding_lines.append(FundingLine(2026, BudgetSource.LOCAL_BUDGET, Decimal("100.00")))
    nodes = [root, sub, activity, obj]

    change_set = ChangeSet(
        status="approved",
        items=[
            ChangeItem(
                node_id="obj1",
                year=2026,
                source_type=BudgetSource.LOCAL_BUDGET,
                old_amount_rub=Decimal("100.00"),
                new_amount_rub=Decimal("250.00"),
                reason="fixture update",
            )
        ],
    )

    apply_changeset(nodes, change_set)
    totals = recalculate_tree(nodes)

    assert totals["obj1"][(2026, BudgetSource.LOCAL_BUDGET)] == Decimal("250.00")
    assert totals["act1"][(2026, BudgetSource.LOCAL_BUDGET)] == Decimal("250.00")
    assert totals["sub1"][(2026, BudgetSource.LOCAL_BUDGET)] == Decimal("250.00")
    assert totals["program"][(2026, BudgetSource.LOCAL_BUDGET)] == Decimal("250.00")

