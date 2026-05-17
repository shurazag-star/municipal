from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal
from enum import Enum
from typing import Dict, List, Optional, Tuple

from .budget_sources import BudgetSource
from .money import quantize_rub


FundingKey = Tuple[int, BudgetSource]


class NodeType(str, Enum):
    PROGRAM = "program"
    SUBPROGRAM = "subprogram"
    MAIN_ACTIVITY = "main_activity"
    ACTIVITY = "activity"
    OBJECT = "object"
    RESULT = "result"
    RESIDUAL = "residual"


@dataclass
class FundingLine:
    year: int
    source_type: BudgetSource
    amount_rub: Decimal


@dataclass
class ProgramNode:
    id: str
    node_type: NodeType
    name: str
    parent_id: Optional[str] = None
    code: str = ""
    funding_lines: List[FundingLine] = field(default_factory=list)


def recalculate_tree(nodes: List[ProgramNode]) -> Dict[str, Dict[FundingKey, Decimal]]:
    by_id = {node.id: node for node in nodes}
    children: Dict[Optional[str], List[ProgramNode]] = {}
    for node in nodes:
        children.setdefault(node.parent_id, []).append(node)

    totals: Dict[str, Dict[FundingKey, Decimal]] = {}

    def visit(node: ProgramNode) -> Dict[FundingKey, Decimal]:
        node_total: Dict[FundingKey, Decimal] = {}
        for line in node.funding_lines:
            key = (line.year, line.source_type)
            node_total[key] = quantize_rub(node_total.get(key, Decimal("0")) + line.amount_rub)
        for child in children.get(node.id, []):
            for key, amount in visit(child).items():
                node_total[key] = quantize_rub(node_total.get(key, Decimal("0")) + amount)
        totals[node.id] = node_total
        return node_total

    for node in nodes:
        if node.parent_id is None or node.parent_id not in by_id:
            visit(node)
    return totals

