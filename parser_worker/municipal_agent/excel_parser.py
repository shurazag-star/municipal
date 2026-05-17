from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal
import re
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Tuple

from openpyxl import load_workbook

from .budget_sources import BudgetSource, normalize_budget_source
from .money import parse_money_to_rub, quantize_rub
from .normalization import normalize_name
from .row_classification import ExcelRowType, classify_excel_row


FundingKey = Tuple[int, BudgetSource]


@dataclass
class ExcelFinanceRow:
    row_number: int
    row_type: ExcelRowType
    parent_activity_code: str = ""
    object_code: str = ""
    object_name: str = ""
    funding: Dict[FundingKey, Decimal] = field(default_factory=dict)
    raw_values: Dict[str, object] = field(default_factory=dict)
    explicit_zero_target: bool = False


@dataclass
class ExcelObjectGroup:
    group_key: str
    status: str
    rows: List[ExcelFinanceRow] = field(default_factory=list)
    funding: Dict[FundingKey, Decimal] = field(default_factory=dict)
    explicit_zero_target: bool = False

    def total_by_year(self) -> Dict[int, Decimal]:
        totals: Dict[int, Decimal] = {}
        for (year, _source), amount in self.funding.items():
            totals[year] = quantize_rub(totals.get(year, Decimal("0")) + amount)
        return totals


@dataclass
class ParsedExcelReport:
    sheet_name: str
    rows: List[ExcelFinanceRow]
    program_totals: Dict[int, Decimal]
    final_totals: Dict[int, Decimal]
    object_groups: List[ExcelObjectGroup]

    def total_without_double_count(self) -> Dict[int, Decimal]:
        if self.program_totals:
            return dict(self.program_totals)
        totals: Dict[int, Decimal] = {}
        for group in self.object_groups:
            for year, amount in group.total_by_year().items():
                totals[year] = quantize_rub(totals.get(year, Decimal("0")) + amount)
        return totals


def group_excel_object_rows(rows: Iterable[ExcelFinanceRow]) -> List[ExcelObjectGroup]:
    groups: Dict[str, ExcelObjectGroup] = {}
    for row in rows:
        if row.row_type not in {ExcelRowType.OBJECT_LEAF_ROW, ExcelRowType.UNASSIGNED_RESIDUAL_ROW}:
            continue
        if row.row_type == ExcelRowType.UNASSIGNED_RESIDUAL_ROW:
            group_key = f"UNASSIGNED_RESIDUAL::{row.parent_activity_code}::{row.row_number}"
            status = "UNASSIGNED_RESIDUAL"
        else:
            object_identity = row.object_code.strip() or normalize_name(row.object_name)
            group_key = "::".join([row.parent_activity_code.strip(), object_identity, normalize_name(row.object_name)])
            status = "GROUPED_OBJECT"

        group = groups.setdefault(group_key, ExcelObjectGroup(group_key=group_key, status=status))
        group.rows.append(row)
        group.explicit_zero_target = group.explicit_zero_target or row.explicit_zero_target
        for key, amount in row.funding.items():
            group.funding[key] = quantize_rub(group.funding.get(key, Decimal("0")) + amount)

    return list(groups.values())


def parse_xlsx_finance_report(path: str | Path) -> ParsedExcelReport:
    workbook = load_workbook(filename=path, data_only=True)
    sheet_name = "Результат" if "Результат" in workbook.sheetnames else workbook.sheetnames[0]
    worksheet = workbook[sheet_name]

    data_start_row, headers = _detect_header(worksheet)
    amount_columns = _detect_amount_columns(headers)
    rows: List[ExcelFinanceRow] = []
    program_totals: Dict[int, Decimal] = {}
    final_totals: Dict[int, Decimal] = {}

    for row_cells in worksheet.iter_rows(min_row=data_start_row, values_only=False):
        values = {header: row_cells[idx].value for idx, header in headers.items()}
        normalized = _normalize_row_values(values)
        row_type = classify_excel_row(normalized)
        funding = _extract_funding(row_cells, amount_columns)
        finance_row = ExcelFinanceRow(
            row_number=row_cells[0].row,
            row_type=row_type,
            parent_activity_code=normalized["measure_code"],
            object_code=normalized["object_code"],
            object_name=normalized["object_name"],
            funding=funding,
            raw_values=values,
            explicit_zero_target=row_type == ExcelRowType.OBJECT_LEAF_ROW and bool(amount_columns) and not funding,
        )
        rows.append(finance_row)
        if row_type == ExcelRowType.PROGRAM_TOTAL_ROW:
            program_totals.update(_extract_total_columns(row_cells, amount_columns))
        elif row_type == ExcelRowType.FINAL_TOTAL_ROW:
            final_totals.update(_extract_total_columns(row_cells, amount_columns))

    return ParsedExcelReport(
        sheet_name=sheet_name,
        rows=rows,
        program_totals=program_totals,
        final_totals=final_totals,
        object_groups=group_excel_object_rows(rows),
    )


def _detect_header(worksheet) -> Tuple[int, Dict[int, str]]:
    for row_cells in worksheet.iter_rows(values_only=False):
        texts = ["" if cell.value is None else str(cell.value).strip() for cell in row_cells]
        if any("наименование" in text.lower() for text in texts):
            header_start = row_cells[0].row
            header_rows = [row_cells]
            data_start = header_start + 1
            for candidate in worksheet.iter_rows(min_row=header_start + 1, max_row=header_start + 4, values_only=False):
                candidate_texts = ["" if cell.value is None else str(cell.value).strip() for cell in candidate]
                filled = [text for text in candidate_texts if text]
                if filled and all(_is_header_number(text) for text in filled):
                    data_start = candidate[0].row + 1
                    break
                joined = " ".join(candidate_texts).lower().replace("ё", "е")
                if any(marker in joined for marker in ["код ", "в том числе", "средства", "всего на"]):
                    header_rows.append(candidate)
                    data_start = candidate[0].row + 1
                else:
                    data_start = candidate[0].row
                    break
            headers: Dict[int, str] = {}
            max_columns = max(len(row) for row in header_rows)
            for idx in range(max_columns):
                parts = []
                for header_row in header_rows:
                    if idx < len(header_row):
                        value = header_row[idx].value
                        if value not in (None, ""):
                            parts.append(str(value).replace("_x000D_", " ").replace("\n", " ").strip())
                if parts:
                    headers[idx] = " ".join(parts)
            return data_start, headers
    raise ValueError("Excel header row was not found")


def _is_header_number(text: str) -> bool:
    return str(text).strip().isdigit()


def _normalize_row_values(values: Mapping[str, object]) -> Dict[str, str]:
    return {
        "name": _lookup_name(values),
        "program_code": _lookup_program_code(values),
        "measure_code": _lookup_measure_code(values),
        "object_code": _lookup_object_code(values),
        "object_name": _lookup_object_name(values),
    }


def _lookup_by_predicate(values: Mapping[str, object], predicate) -> str:
    for header, value in values.items():
        header_norm = header.lower().replace("ё", "е")
        if predicate(header_norm):
            return "" if value is None else str(value).strip()
    return ""


def _lookup_name(values: Mapping[str, object]) -> str:
    return _lookup_by_predicate(values, lambda header: header.startswith("наименование") and "объект" not in header)


def _lookup_program_code(values: Mapping[str, object]) -> str:
    return _lookup_by_predicate(values, lambda header: "код цел" in header or "код программы" in header)


def _lookup_measure_code(values: Mapping[str, object]) -> str:
    value = _lookup_by_predicate(values, lambda header: header.strip().startswith("мероприятие"))
    if value:
        return value
    return _lookup_by_predicate(values, lambda header: "код мероприятия" in header and "код цел" not in header)


def _lookup_object_code(values: Mapping[str, object]) -> str:
    return _lookup_by_predicate(values, lambda header: "объект" in header and "наименование" not in header)


def _lookup_object_name(values: Mapping[str, object]) -> str:
    return _lookup_by_predicate(values, lambda header: "наименование" in header and "объект" in header)


def _detect_amount_columns(headers: Mapping[int, str]) -> Dict[int, Tuple[int, Optional[BudgetSource]]]:
    columns: Dict[int, Tuple[int, Optional[BudgetSource]]] = {}
    current_year: Optional[int] = None
    in_plan_columns = True
    for idx, header in sorted(headers.items()):
        text = header.lower().replace("ё", "е")
        if any(marker in text for marker in ["поставлено", "фактически", "% исполнения"]):
            in_plan_columns = False
        if not in_plan_columns:
            continue
        match = re.search(r"(20\d{2})", text)
        if match:
            current_year = int(match.group(1))
        source = normalize_budget_source(text)
        if match and "всего" in text:
            columns[idx] = (current_year, None)
        elif current_year is not None and source is not BudgetSource.UNKNOWN:
            columns[idx] = (current_year, source)
    return columns


def _extract_funding(row_cells, amount_columns: Mapping[int, Tuple[int, Optional[BudgetSource]]]) -> Dict[FundingKey, Decimal]:
    specific: Dict[FundingKey, Decimal] = {}
    totals: Dict[int, Decimal] = {}
    for idx, (year, source) in amount_columns.items():
        amount = parse_money_to_rub(row_cells[idx].value)
        if amount == Decimal("0.00"):
            continue
        if source is None:
            totals[year] = amount
        else:
            specific[(year, source)] = amount
    if specific:
        return specific
    return {(year, BudgetSource.UNKNOWN): amount for year, amount in totals.items()}


def _extract_total_columns(row_cells, amount_columns: Mapping[int, Tuple[int, Optional[BudgetSource]]]) -> Dict[int, Decimal]:
    totals: Dict[int, Decimal] = {}
    for idx, (year, source) in amount_columns.items():
        if source is None:
            amount = parse_money_to_rub(row_cells[idx].value)
            if amount != Decimal("0.00"):
                totals[year] = amount
    return totals
