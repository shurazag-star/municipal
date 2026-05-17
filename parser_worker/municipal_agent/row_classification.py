from __future__ import annotations

from enum import Enum
import re
from typing import Mapping, Sequence

from .budget_sources import BudgetSource, normalize_budget_source


class DocxRowType(str, Enum):
    SUBPROGRAM_TOTAL_ROW = "SUBPROGRAM_TOTAL_ROW"
    MAIN_ACTIVITY_ROW = "MAIN_ACTIVITY_ROW"
    ACTIVITY_ROW = "ACTIVITY_ROW"
    OBJECT_ROW = "OBJECT_ROW"
    SOURCE_ROW = "SOURCE_ROW"
    RESULT_ROW = "RESULT_ROW"
    HEADER_ROW = "HEADER_ROW"
    EMPTY_ROW = "EMPTY_ROW"
    UNKNOWN_ROW = "UNKNOWN_ROW"


class ExcelRowType(str, Enum):
    PROGRAM_TOTAL_ROW = "PROGRAM_TOTAL_ROW"
    SUBPROGRAM_ROW = "SUBPROGRAM_ROW"
    MAIN_ACTIVITY_ROW = "MAIN_ACTIVITY_ROW"
    ACTIVITY_AGGREGATE_ROW = "ACTIVITY_AGGREGATE_ROW"
    OBJECT_LEAF_ROW = "OBJECT_LEAF_ROW"
    UNASSIGNED_RESIDUAL_ROW = "UNASSIGNED_RESIDUAL_ROW"
    FINAL_TOTAL_ROW = "FINAL_TOTAL_ROW"
    HEADER_ROW = "HEADER_ROW"
    EMPTY_ROW = "EMPTY_ROW"
    UNKNOWN_ROW = "UNKNOWN_ROW"


def _joined(cells: Sequence[object]) -> str:
    return " ".join("" if cell is None else str(cell) for cell in cells).lower().replace("ё", "е").strip()


def classify_docx_row(cells: Sequence[object]) -> DocxRowType:
    text = _joined(cells)
    if not text:
        return DocxRowType.EMPTY_ROW
    if "источник" in text and re.search(r"20\d{2}", text):
        return DocxRowType.HEADER_ROW
    if "итого по подпрограмме" in text:
        return DocxRowType.SUBPROGRAM_TOTAL_ROW
    if normalize_budget_source(text) is not BudgetSource.UNKNOWN:
        return DocxRowType.SOURCE_ROW
    if "результат" in text:
        return DocxRowType.RESULT_ROW
    if "основное мероприятие" in text:
        return DocxRowType.MAIN_ACTIVITY_ROW
    if re.match(r"^\s*\d+\.\d+\.\d+", text):
        return DocxRowType.OBJECT_ROW
    if "мероприятие" in text or re.match(r"^\s*\d+\.\d+", text):
        return DocxRowType.ACTIVITY_ROW
    return DocxRowType.UNKNOWN_ROW


def _field(row: Mapping[str, object], key: str) -> str:
    return "" if row.get(key) is None else str(row.get(key)).strip()


def classify_excel_row(row: Mapping[str, object]) -> ExcelRowType:
    name = _field(row, "name").lower().replace("ё", "е")
    program_code = _field(row, "program_code")
    measure_code = _field(row, "measure_code")
    object_code = _field(row, "object_code")
    object_name = _field(row, "object_name")

    if not any([name, program_code, measure_code, object_code, object_name]):
        return ExcelRowType.EMPTY_ROW
    if name.startswith("итого"):
        return ExcelRowType.FINAL_TOTAL_ROW
    if object_code == "0000000000.0000000000":
        return ExcelRowType.UNASSIGNED_RESIDUAL_ROW
    if object_code or object_name:
        return ExcelRowType.OBJECT_LEAF_ROW
    if "муниципальная программа" in name:
        return ExcelRowType.PROGRAM_TOTAL_ROW
    if "подпрограмма" in name:
        return ExcelRowType.SUBPROGRAM_ROW
    if "основное мероприятие" in name:
        return ExcelRowType.MAIN_ACTIVITY_ROW
    if "мероприятие" in name or measure_code:
        return ExcelRowType.ACTIVITY_AGGREGATE_ROW
    return ExcelRowType.UNKNOWN_ROW

