from __future__ import annotations

from dataclasses import asdict, is_dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any

from .agreement_pdf_parser import parse_pdf_agreement as _parse_pdf_agreement
from .docx_parser import parse_docx_program as _parse_docx_program
from .excel_parser import parse_xlsx_finance_report as _parse_xlsx_finance_report
from .procedure_pdf_parser import parse_pdf_procedure as _parse_pdf_procedure
from .reconcile import compare_program_totals as _compare_program_totals

"""
Parser-facing helpers only.

The Rails application owns the runtime agent tool layer through
AgentToolRegistry. This module intentionally exposes only parser/math helpers
that are safe to call from Python tests or one-off scripts; workflow actions
such as program persistence, autonomous resolution, DOCX patching and report
generation must go through Rails services.
"""


def parse_docx_program(file_path: str) -> dict:
    return _to_jsonable(_parse_docx_program(Path(file_path)))


def parse_xlsx_finance_report(file_path: str) -> dict:
    return _to_jsonable(_parse_xlsx_finance_report(Path(file_path)))


def validate_program_totals(docx_totals_by_year: dict[int, Decimal], external_totals_by_year: dict[int, Decimal]) -> dict:
    return {"diffs": _to_jsonable(_compare_program_totals(docx_totals_by_year, external_totals_by_year))}


def parse_pdf_procedure(file_path: str) -> dict:
    return _to_jsonable(_parse_pdf_procedure(Path(file_path)))


def parse_pdf_agreement(file_id: str) -> dict:
    return _to_jsonable(_parse_pdf_agreement(Path(file_id)))


def _to_jsonable(value: Any) -> Any:
    if isinstance(value, Decimal):
        return str(value)
    if is_dataclass(value):
        return _to_jsonable(asdict(value))
    if isinstance(value, dict):
        return {str(_to_jsonable(key)): _to_jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_to_jsonable(item) for item in value]
    if hasattr(value, "value") and value.__class__.__module__.startswith("municipal_agent"):
        return value.value
    return value
