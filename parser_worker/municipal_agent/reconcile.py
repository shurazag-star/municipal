from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Dict, List

from .money import quantize_rub


@dataclass
class ReconciliationDiff:
    status: str
    year: int
    docx_amount_rub: Decimal
    external_amount_rub: Decimal
    delta_rub: Decimal


def compare_program_totals(
    docx_totals_by_year: Dict[int, Decimal],
    external_totals_by_year: Dict[int, Decimal],
    tolerance_rub: Decimal = Decimal("10.00"),
) -> List[ReconciliationDiff]:
    diffs: List[ReconciliationDiff] = []
    for year in sorted(set(docx_totals_by_year) | set(external_totals_by_year)):
        docx_amount = quantize_rub(docx_totals_by_year.get(year, Decimal("0")))
        external_amount = quantize_rub(external_totals_by_year.get(year, Decimal("0")))
        delta = quantize_rub(external_amount - docx_amount)
        if abs(delta) > tolerance_rub:
            diffs.append(
                ReconciliationDiff(
                    status="PROGRAM_TOTAL_DIFF",
                    year=year,
                    docx_amount_rub=docx_amount,
                    external_amount_rub=external_amount,
                    delta_rub=delta,
                )
            )
    return diffs

