from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal
from typing import List

from .budget_sources import BudgetSource
from .program_tree import FundingLine, ProgramNode


@dataclass
class ChangeItem:
    node_id: str
    year: int
    source_type: BudgetSource
    old_amount_rub: Decimal
    new_amount_rub: Decimal
    reason: str
    requires_user_confirmation: bool = False


@dataclass
class ChangeSet:
    status: str = "draft"
    items: List[ChangeItem] = field(default_factory=list)
    summary: str = ""


def apply_changeset(nodes: List[ProgramNode], change_set: ChangeSet) -> None:
    if change_set.status not in {"approved", "applied"}:
        raise ValueError("ChangeSet must be approved before applying")
    by_id = {node.id: node for node in nodes}
    for item in change_set.items:
        node = by_id[item.node_id]
        matching = [
            line
            for line in node.funding_lines
            if line.year == item.year and line.source_type == item.source_type
        ]
        if matching:
            matching[0].amount_rub = item.new_amount_rub
        else:
            node.funding_lines.append(FundingLine(item.year, item.source_type, item.new_amount_rub))
    change_set.status = "applied"

