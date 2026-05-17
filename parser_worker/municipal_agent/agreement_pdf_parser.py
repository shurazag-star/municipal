from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Any, Dict, List

from pypdf import PdfReader

from .budget_sources import BudgetSource, normalize_budget_source
from .money import parse_money_to_rub, quantize_rub


@dataclass
class AgreementChange:
    object_name: str
    event_name: str | None
    year: int
    amount_mode: str
    budget_source: str
    source_type: str
    old_amount: str | None
    old_amount_rub: str | None
    new_amount: str | None
    new_amount_rub: str | None
    amount_rub: str | None
    delta_amount: str | None
    delta_rub: str | None
    from_year: int | None
    to_year: int | None
    evidence_text: str
    excerpt: str
    page: int
    page_number: int
    confidence: float
    table_type: str | None = None


@dataclass
class ParsedAgreementPdf:
    document_type: str = "pdf_agreement"
    page_count: int = 0
    text_char_count: int = 0
    text_extraction_method: str = "text_layer"
    normalized_text: str = ""
    changes: List[AgreementChange] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    pages: List[Dict[str, str | int]] = field(default_factory=list)
    pdf_profile: Dict[str, Any] = field(default_factory=dict)
    pdf_control_sums: Dict[str, Any] = field(default_factory=dict)


MONEY_RE = re.compile(
    r"(?P<value>\d[\d\s\u00a0\u202f]*(?:[,.]\d{1,5})?)\s*"
    r"(?P<thousand>тыс\.?\s*)?"
    r"(?:руб(?:\.|лей|ля|ль)?|₽)",
    flags=re.IGNORECASE,
)
MIN_TEXT_LAYER_CHARS = 80
YEAR_RE = re.compile(r"\b(20\d{2})\b")
QUOTED_OBJECT_RE = re.compile(r"[«\"](?P<object>[^»\"]{3,240})[»\"]")
PLAIN_OBJECT_RE = re.compile(
    r"(?:по\s+)?объект[ауе]?\s+(?P<object>.{4,180}?)(?:\s+на\s+20\d{2}|\s+в\s+20\d{2}|[,.;]|$)",
    flags=re.IGNORECASE,
)

BUDGET_SOURCE_LABELS = {
    BudgetSource.FEDERAL_BUDGET: "federal",
    BudgetSource.REGIONAL_BUDGET: "regional",
    BudgetSource.LOCAL_BUDGET: "local",
    BudgetSource.MUNICIPAL_BUDGET: "municipal",
    BudgetSource.EXTRABUDGETARY: "extrabudgetary",
    BudgetSource.PRIVATE_FUNDS: "private",
    BudgetSource.OTHER_SOURCE: "other",
    BudgetSource.UNKNOWN: "unknown",
}
PDF_APPENDIX_YEAR_COLUMNS = {
    2023: {"regional": 542.9, "local": 716.5},
    2024: {"regional": 560.3, "local": 733.9},
    2025: {"regional": 577.6, "local": 751.2},
    2026: {"regional": 595.0, "local": 768.6},
    2027: {"regional": 612.3, "local": 785.2},
}
PDF_APPENDIX_COLUMN_RADIUS = 8.5
PDF_COMPACT_APPENDIX_AMOUNT_COLUMNS = {
    (2026, BudgetSource.REGIONAL_BUDGET): (520.0, 570.0),
    (2027, BudgetSource.REGIONAL_BUDGET): (570.0, 625.0),
    (2026, BudgetSource.LOCAL_BUDGET): (705.0, 750.0),
    (2027, BudgetSource.LOCAL_BUDGET): (750.0, 805.0),
}


def parse_pdf_agreement(path: str | Path) -> ParsedAgreementPdf:
    reader = PdfReader(str(path))
    raw_pages = [page.extract_text() or "" for page in reader.pages]
    positioned_pages = _positioned_text_pages(reader)
    raw_text = "\n".join(raw_pages)
    text_extraction_method = "text_layer"
    pages = [
        {
            "page_number": index,
            "text": raw_text.strip(),
            "normalized_text": _normalize_text(raw_text),
        }
        for index, raw_text in enumerate(raw_pages, start=1)
    ]
    warnings: list[str] = []

    if len(_normalize_text(raw_text)) < MIN_TEXT_LAYER_CHARS:
        try:
            ocr_pages = _ocr_pages(Path(path), len(reader.pages))
        except OcrError as error:
            ocr_pages = []
            warnings.append(f"OCR недоступен или не выполнен: {error}")

        if ocr_pages:
            pages = ocr_pages
            raw_text = "\n".join(str(page.get("text") or "") for page in ocr_pages)
            text_extraction_method = "ocr"
            warnings.append("OCR применен: PDF не содержал достаточного текстового слоя.")

    normalized_text = _normalize_text(raw_text)
    budget_table_analysis = _analyze_budget_tables_from_positioned_pages(positioned_pages)
    changes = _deduplicate_changes(
        extract_agreement_changes_from_pages(pages) +
        budget_table_analysis["changes"]
    )
    pdf_profile = {
        "tables": budget_table_analysis["tables"],
        "table_count": len(budget_table_analysis["tables"]),
        "detected_table_types": sorted({table["table_type"] for table in budget_table_analysis["tables"]}),
    }
    pdf_control_sums = budget_table_analysis["control_sums"]
    if not normalized_text:
        warnings.append("PDF не содержит извлекаемого текстового слоя; требуется OCR или ручная проверка.")
    elif not changes:
        warnings.append("Структурированные изменения в PDF не найдены.")
    if pdf_control_sums.get("status") == "failed":
        warnings.append("Контрольные суммы PDF-таблицы не сходятся с итоговой строкой.")

    return ParsedAgreementPdf(
        page_count=len(reader.pages),
        text_char_count=len(raw_text),
        text_extraction_method=text_extraction_method,
        normalized_text=normalized_text,
        changes=changes,
        warnings=warnings,
        pages=pages,
        pdf_profile=pdf_profile,
        pdf_control_sums=pdf_control_sums,
    )


def _positioned_text_pages(reader: PdfReader) -> List[Dict[str, Any]]:
    pages: list[dict[str, Any]] = []
    for page_number, page in enumerate(reader.pages, start=1):
        items: list[dict[str, Any]] = []

        def visitor(text: str, cm: list[float], tm: list[float], _font_dict: Any, font_size: float) -> None:
            if not text or not text.strip():
                return

            x = float(tm[4] or cm[4] or 0)
            y = float(tm[5] or cm[5] or 0)
            items.append({"x": x, "y": y, "text": text, "font_size": float(font_size or 0)})

        try:
            page.extract_text(visitor_text=visitor)
        except Exception:
            items = []

        pages.append({"page_number": page_number, "items": items})
    return pages


def _deduplicate_changes(changes: List[AgreementChange]) -> List[AgreementChange]:
    unique: list[AgreementChange] = []
    seen: set[tuple[str, str | None, int, str, str | None, str]] = set()
    for change in changes:
        key = (
            _normalize_text(change.object_name),
            _normalize_text(change.event_name or "") if change.event_name else None,
            change.year,
            change.source_type,
            change.amount_rub,
            change.amount_mode,
        )
        if key in seen:
            continue
        seen.add(key)
        unique.append(change)
    return unique


def _extract_budget_table_changes_from_positioned_pages(positioned_pages: List[Dict[str, Any]]) -> List[AgreementChange]:
    return _analyze_budget_tables_from_positioned_pages(positioned_pages)["changes"]


def _analyze_budget_tables_from_positioned_pages(positioned_pages: List[Dict[str, Any]]) -> Dict[str, Any]:
    changes: list[AgreementChange] = []
    tables: list[dict[str, Any]] = []

    for page in positioned_pages:
        page_number = int(page.get("page_number") or 0)
        items = [
            item for item in page.get("items", [])
            if _clean_pdf_text(str(item.get("text") or ""))
        ]
        if not items:
            continue

        total_markers = [
            item for item in items
            if _normalize_text(str(item.get("text") or "")) == "всего" and 360 <= float(item.get("x") or 0) <= 470
        ]
        if not total_markers:
            continue

        total_y = max(float(item.get("y") or 0) for item in total_markers)
        continued_table = _analyze_continued_appendix_table(
            page_number=page_number,
            items=items,
            total_y=total_y,
        )
        if continued_table["changes"]:
            changes.extend(continued_table["changes"])
            tables.append(_table_profile_without_changes(continued_table))
            continue

        single_row_table = _analyze_single_row_appendix_table(
            page_number=page_number,
            items=items,
            total_y=total_y,
        )
        if single_row_table["changes"]:
            changes.extend(single_row_table["changes"])
            tables.append(_table_profile_without_changes(single_row_table))

    return {
        "changes": changes,
        "tables": tables,
        "control_sums": _pdf_control_sums_summary(tables),
    }


def _analyze_single_row_appendix_table(*, page_number: int, items: List[Dict[str, Any]], total_y: float) -> Dict[str, Any]:
    row_items = [
        item for item in items
        if total_y + 8 <= float(item.get("y") or 0) <= total_y + 95
    ]
    total_row_items = _total_row_items(items, total_y)
    event_name = _collect_pdf_text(row_items, min_x=40, max_x=170)
    object_detail = _collect_pdf_text(row_items, min_x=165, max_x=260)
    if not event_name:
        return _empty_table_analysis(page_number, "single_row_appendix_budget_table")

    object_name = event_name
    if object_detail:
        object_name = f"{event_name}: {object_detail}"

    changes: list[AgreementChange] = []
    detail_totals: dict[tuple[int, BudgetSource], Decimal] = {}
    control_totals: dict[tuple[int, BudgetSource], Decimal] = {}

    for year, columns in PDF_APPENDIX_YEAR_COLUMNS.items():
        regional_amount = _parse_pdf_table_amount(row_items, columns["regional"])
        local_amount = _parse_pdf_table_amount(row_items, columns["local"])
        regional_total = _parse_pdf_table_amount(total_row_items, columns["regional"])
        local_total = _parse_pdf_table_amount(total_row_items, columns["local"])

        if regional_amount is not None:
            detail_totals[(year, BudgetSource.REGIONAL_BUDGET)] = regional_amount
            changes.append(_appendix_table_change(object_name=object_name, event_name=event_name, year=year, amount=regional_amount, source=BudgetSource.REGIONAL_BUDGET, page_number=page_number))
        if local_amount is not None:
            detail_totals[(year, BudgetSource.LOCAL_BUDGET)] = local_amount
            changes.append(_appendix_table_change(object_name=object_name, event_name=event_name, year=year, amount=local_amount, source=BudgetSource.LOCAL_BUDGET, page_number=page_number))
        if regional_total is not None:
            control_totals[(year, BudgetSource.REGIONAL_BUDGET)] = regional_total
        if local_total is not None:
            control_totals[(year, BudgetSource.LOCAL_BUDGET)] = local_total

    return {
        "table_type": "single_row_appendix_budget_table",
        "page_number": page_number,
        "row_count": 1 if changes else 0,
        "columns": _single_row_columns_profile(),
        "changes": changes,
        "control_sums": _control_sum_checks(detail_totals, control_totals),
    }


def _analyze_continued_appendix_table(
    *,
    page_number: int,
    items: List[Dict[str, Any]],
    total_y: float,
) -> Dict[str, Any]:
    code_markers = [
        item for item in items
        if 390 <= float(item.get("x") or 0) <= 430
        and float(item.get("y") or 0) > total_y + 8
        and re.fullmatch(r"\d{2}", _clean_pdf_text(str(item.get("text") or "")).strip())
    ]
    code_markers = sorted(code_markers, key=lambda item: -float(item.get("y") or 0))
    if len(code_markers) < 2:
        return _empty_table_analysis(page_number, "continued_appendix_budget_table")

    changes: list[AgreementChange] = []
    detail_totals: dict[tuple[int, BudgetSource], Decimal] = {}
    control_totals: dict[tuple[int, BudgetSource], Decimal] = {}
    current_event_name = ""

    for index, marker in enumerate(code_markers):
        row_top = float(marker.get("y") or 0) + 8
        next_y = float(code_markers[index + 1].get("y") or 0) if index + 1 < len(code_markers) else total_y
        row_bottom = next_y + 2
        row_items = [
            item for item in items
            if row_bottom <= float(item.get("y") or 0) <= row_top
        ]
        event_name = _collect_pdf_text(row_items, min_x=40, max_x=170)
        if len(event_name) >= 25:
            current_event_name = event_name
        event_name = current_event_name
        object_name = _collect_pdf_text(row_items, min_x=165, max_x=260)
        if not event_name or not object_name:
            continue

        for (year, source), (min_x, max_x) in PDF_COMPACT_APPENDIX_AMOUNT_COLUMNS.items():
            amount = _parse_pdf_table_amount_range(row_items, min_x=min_x, max_x=max_x)
            if amount is None:
                continue

            detail_totals[(year, source)] = detail_totals.get((year, source), Decimal("0")) + amount
            changes.append(
                _appendix_table_change(
                    object_name=object_name,
                    event_name=event_name,
                    year=year,
                    amount=amount,
                    source=source,
                    page_number=page_number,
                )
            )

    total_row_items = _total_row_items(items, total_y)
    for (year, source), (min_x, max_x) in PDF_COMPACT_APPENDIX_AMOUNT_COLUMNS.items():
        total = _parse_pdf_table_amount_range(total_row_items, min_x=min_x, max_x=max_x)
        if total is not None:
            control_totals[(year, source)] = total

    return {
        "table_type": "continued_appendix_budget_table",
        "page_number": page_number,
        "row_count": len({change.object_name for change in changes}),
        "columns": _compact_columns_profile(),
        "changes": changes,
        "control_sums": _control_sum_checks(detail_totals, control_totals),
    }


def _empty_table_analysis(page_number: int, table_type: str) -> Dict[str, Any]:
    return {
        "table_type": table_type,
        "page_number": page_number,
        "row_count": 0,
        "columns": {},
        "changes": [],
        "control_sums": {"status": "not_applicable", "checks": []},
    }


def _table_profile_without_changes(table: Dict[str, Any]) -> Dict[str, Any]:
    return {key: value for key, value in table.items() if key != "changes"}


def _total_row_items(items: List[Dict[str, Any]], total_y: float) -> List[Dict[str, Any]]:
    return [
        item for item in items
        if total_y - 18 <= float(item.get("y") or 0) <= total_y + 8
    ]


def _control_sum_checks(
    detail_totals: Dict[tuple[int, BudgetSource], Decimal],
    control_totals: Dict[tuple[int, BudgetSource], Decimal],
) -> Dict[str, Any]:
    checks: list[dict[str, Any]] = []
    for key, control_total in sorted(control_totals.items(), key=lambda item: (item[0][0], item[0][1].value)):
        year, source = key
        detail_total = detail_totals.get(key, Decimal("0"))
        difference = quantize_rub(detail_total - control_total)
        checks.append(
            {
                "year": year,
                "source_type": source.value,
                "detail_total_rub": _decimal_to_text(detail_total),
                "control_total_rub": _decimal_to_text(control_total),
                "difference_rub": _decimal_to_text(difference),
                "status": "passed" if difference.copy_abs() <= Decimal("0.01") else "failed",
            }
        )

    if not checks:
        status = "not_applicable"
    elif any(check["status"] == "failed" for check in checks):
        status = "failed"
    else:
        status = "passed"

    return {"status": status, "checks": checks}


def _pdf_control_sums_summary(tables: List[Dict[str, Any]]) -> Dict[str, Any]:
    checks = [
        check
        for table in tables
        for check in table.get("control_sums", {}).get("checks", [])
    ]
    if not checks:
        status = "not_applicable"
    elif any(check["status"] == "failed" for check in checks):
        status = "failed"
    else:
        status = "passed"

    return {
        "status": status,
        "checks": checks,
        "checked_table_count": sum(1 for table in tables if table.get("control_sums", {}).get("checks")),
        "failed_check_count": sum(1 for check in checks if check["status"] == "failed"),
    }


def _compact_columns_profile() -> Dict[str, Any]:
    return {
        f"{year}::{source.value}": {"min_x": bounds[0], "max_x": bounds[1]}
        for (year, source), bounds in PDF_COMPACT_APPENDIX_AMOUNT_COLUMNS.items()
    }


def _single_row_columns_profile() -> Dict[str, Any]:
    result: dict[str, Any] = {}
    for year, columns in PDF_APPENDIX_YEAR_COLUMNS.items():
        result[f"{year}::{BudgetSource.REGIONAL_BUDGET.value}"] = {"x": columns["regional"], "radius": PDF_APPENDIX_COLUMN_RADIUS}
        result[f"{year}::{BudgetSource.LOCAL_BUDGET.value}"] = {"x": columns["local"], "radius": PDF_APPENDIX_COLUMN_RADIUS}
    return result


def _appendix_table_change(
    *,
    object_name: str,
    event_name: str,
    year: int,
    amount: Decimal,
    source: BudgetSource,
    page_number: int,
) -> AgreementChange:
    amount_text = _decimal_to_text(amount)
    evidence = f"{event_name}; {source.value}; {year}: {amount_text} руб."
    return AgreementChange(
        object_name=_clean_object_name(object_name),
        event_name=_clean_object_name(event_name),
        year=year,
        amount_mode="absolute",
        budget_source=BUDGET_SOURCE_LABELS[source],
        source_type=source.value,
        old_amount=None,
        old_amount_rub=None,
        new_amount=amount_text,
        new_amount_rub=amount_text,
        amount_rub=amount_text,
        delta_amount=None,
        delta_rub=None,
        from_year=None,
        to_year=None,
        evidence_text=evidence,
        excerpt=evidence,
        page=page_number,
        page_number=page_number,
        confidence=0.95,
        table_type="appendix_budget_table",
    )


def _collect_pdf_text(items: List[Dict[str, Any]], *, min_x: float, max_x: float) -> str:
    selected = [
        item for item in items
        if min_x <= float(item.get("x") or 0) < max_x and not _is_pdf_amount_fragment(str(item.get("text") or ""))
    ]
    if not selected:
        return ""

    lines: list[list[dict[str, Any]]] = []
    for item in sorted(selected, key=lambda value: -float(value.get("y") or 0)):
        y = float(item.get("y") or 0)
        if not lines or abs(float(lines[-1][0].get("y") or 0) - y) > 3:
            lines.append([item])
        else:
            lines[-1].append(item)

    line_texts = [
        "".join(_clean_pdf_text(str(part.get("text") or "")) for part in sorted(line, key=lambda value: float(value.get("x") or 0)))
        for line in lines
    ]
    text = _join_pdf_text_lines(line_texts)
    return _clean_object_name(_fix_common_pdf_join_artifacts(text))


def _join_pdf_text_lines(line_texts: List[str]) -> str:
    text = ""
    for raw_line in line_texts:
        line = raw_line.strip()
        if not line:
            continue
        if not text:
            text = line
            continue
        if _pdf_line_needs_space(text, line):
            text += " " + line
        else:
            text += line
    return text


def _pdf_line_needs_space(previous: str, current: str) -> bool:
    current_normalized = current.strip().lower()
    if current_normalized.startswith(("м.", "ул.", "г.", "д.", "(в", "в ", "на ", "от ", "до ", "№")):
        return True
    if previous.rstrip().endswith((".", ")", "»")):
        return True
    return False


def _fix_common_pdf_join_artifacts(text: str) -> str:
    replacements = (
        ("насосныхстанций", "насосных станций"),
        ("муниципальнойсобственности", "муниципальной собственности"),
        ("м.о.", " м.о."),
        ("  м.о.", " м.о."),
    )
    for left, right in replacements:
        text = text.replace(left, right)
    return re.sub(r"[\u00a0\u202f\s]+", " ", text).strip()


def _is_pdf_amount_fragment(value: str) -> bool:
    text = _clean_pdf_text(value)
    return bool(re.fullmatch(r"[\d\s,.]+", text))


def _parse_pdf_table_amount(items: List[Dict[str, Any]], column_x: float) -> Decimal | None:
    fragments = [
        item for item in items
        if abs(float(item.get("x") or 0) - column_x) <= PDF_APPENDIX_COLUMN_RADIUS and _is_pdf_amount_fragment(str(item.get("text") or ""))
    ]
    if not fragments:
        return None

    raw = "".join(
        _clean_pdf_text(str(item.get("text") or ""))
        for item in sorted(fragments, key=lambda value: (-float(value.get("y") or 0), float(value.get("x") or 0)))
    )
    raw = re.sub(r"[^\d,.]", "", raw)
    if not re.search(r"\d", raw):
        return None

    return parse_money_to_rub(raw, unit="rub")


def _parse_pdf_table_amount_range(items: List[Dict[str, Any]], *, min_x: float, max_x: float) -> Decimal | None:
    fragments = [
        item for item in items
        if min_x <= float(item.get("x") or 0) < max_x and _is_pdf_amount_fragment(str(item.get("text") or ""))
    ]
    if not fragments:
        return None

    raw = "".join(
        _clean_pdf_text(str(item.get("text") or ""))
        for item in sorted(fragments, key=lambda value: (-float(value.get("y") or 0), float(value.get("x") or 0)))
    )
    raw = re.sub(r"[^\d,.]", "", raw)
    if not re.search(r"\d", raw):
        return None

    return parse_money_to_rub(raw, unit="rub")


def _clean_pdf_text(value: str) -> str:
    value = value.replace("\u200b", "").replace("\ufeff", "")
    value = value.replace("\r", "").replace("\n", "")
    return re.sub(r"[\u00a0\u202f\s]+", " ", value)


class OcrError(RuntimeError):
    pass


def _ocr_pages(path: Path, page_count: int) -> List[Dict[str, str | int]]:
    pdftoppm = shutil.which("pdftoppm")
    tesseract = shutil.which("tesseract")
    if not pdftoppm:
        raise OcrError("pdftoppm не установлен")
    if not tesseract:
        raise OcrError("tesseract не установлен")

    with tempfile.TemporaryDirectory(prefix="agreement_pdf_ocr") as tmpdir:
        prefix = str(Path(tmpdir) / "page")
        _run_command([pdftoppm, "-r", "250", "-png", str(path), prefix])
        images = sorted(Path(tmpdir).glob("page-*.png"), key=_page_image_sort_key)
        if not images and page_count:
            raise OcrError("pdftoppm не создал PNG-страницы")

        pages: list[dict[str, str | int]] = []
        for index, image_path in enumerate(images, start=1):
            text = _ocr_image(tesseract, image_path)
            pages.append(
                {
                    "page_number": index,
                    "text": text.strip(),
                    "normalized_text": _normalize_text(text),
                    "extraction_method": "ocr",
                }
            )
        return pages


def _ocr_image(tesseract: str, image_path: Path) -> str:
    result = _run_command([tesseract, str(image_path), "stdout", "-l", "rus+eng", "--psm", "6"], check=False)
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout

    fallback = _run_command([tesseract, str(image_path), "stdout", "-l", "rus+eng", "--psm", "11"], check=False)
    if fallback.returncode != 0:
        raise OcrError(f"tesseract не распознал страницу: {fallback.stderr.strip()}")
    return fallback.stdout


def _run_command(argv: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(argv, check=False, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise OcrError(result.stderr.strip() or f"Команда завершилась с кодом {result.returncode}: {' '.join(argv)}")
    return result


def _page_image_sort_key(path: Path) -> int:
    match = re.search(r"-(\d+)\.png$", path.name)
    return int(match.group(1)) if match else 0


def extract_agreement_changes_from_pages(pages: List[Dict[str, Any]]) -> List[AgreementChange]:
    changes: list[AgreementChange] = []
    seen: set[tuple[str, int, str, str]] = set()

    for page in pages:
        page_number = int(page.get("page_number") or 0)
        text = str(page.get("text") or page.get("normalized_text") or "")
        for window in _candidate_windows(text):
            change = _change_from_window(window, page_number)
            if change is None:
                continue

            key = (change.object_name.lower(), change.year, change.source_type, change.amount_rub)
            if key in seen:
                continue
            seen.add(key)
            changes.append(change)

    return changes


def _change_from_window(window: str, page_number: int) -> AgreementChange | None:
    mode = _amount_mode(window)
    years = [int(match.group(1)) for match in YEAR_RE.finditer(window)]
    if not years:
        return None

    amounts = _extract_amounts(window)
    if not amounts and mode != "zeroing":
        return None

    object_name = _extract_object_name(window)
    if not object_name:
        return None

    source = normalize_budget_source(window)
    old_amount: Decimal | None = None
    new_amount: Decimal | None = None
    amount_rub: Decimal | None = None
    delta: Decimal | None = None
    from_year: int | None = None
    to_year: int | None = None

    if mode == "delta_plus":
        delta = amounts[-1]
    elif mode == "delta_minus":
        delta = -amounts[-1]
    elif mode == "transfer":
        from_year = years[0] if years else None
        to_year = years[1] if len(years) > 1 else None
        delta = amounts[-1]
    elif mode == "zeroing":
        new_amount = Decimal("0")
        amount_rub = new_amount
    else:
        old_amount = amounts[0] if len(amounts) > 1 else None
        new_amount = amounts[-1] if amounts else None
        amount_rub = new_amount
        delta = quantize_rub(new_amount - old_amount) if old_amount is not None and new_amount is not None else None

    evidence = _trim_evidence(window)
    confidence = _confidence(object_name=object_name, source=source, old_amount=old_amount, amount_count=len(amounts), mode=mode)

    return AgreementChange(
        object_name=object_name,
        event_name=None,
        year=to_year or years[-1],
        amount_mode=mode,
        budget_source=BUDGET_SOURCE_LABELS[source],
        source_type=source.value,
        old_amount=_decimal_to_text(old_amount) if old_amount is not None else None,
        old_amount_rub=_decimal_to_text(old_amount) if old_amount is not None else None,
        new_amount=_decimal_to_text(new_amount) if new_amount is not None else None,
        new_amount_rub=_decimal_to_text(new_amount) if new_amount is not None else None,
        amount_rub=_decimal_to_text(amount_rub) if amount_rub is not None else None,
        delta_amount=_decimal_to_text(delta) if delta is not None else None,
        delta_rub=_decimal_to_text(delta) if delta is not None else None,
        from_year=from_year,
        to_year=to_year,
        evidence_text=evidence,
        excerpt=evidence,
        page=page_number,
        page_number=page_number,
        confidence=confidence,
    )


def _candidate_windows(text: str) -> List[str]:
    normalized = re.sub(r"[\u00a0\u202f\s]+", " ", text).strip()
    if not normalized:
        return []

    sentences = re.split(r"(?<=[.!?])\s+", normalized)
    windows: list[str] = []
    for sentence in sentences:
        if YEAR_RE.search(sentence) and (MONEY_RE.search(sentence) or _amount_mode(sentence) == "zeroing"):
            windows.append(sentence)

    if windows:
        return windows

    chunks: list[str] = []
    words = normalized.split()
    for start in range(0, len(words), 80):
        chunk = " ".join(words[start : start + 120])
        if YEAR_RE.search(chunk) and (MONEY_RE.search(chunk) or _amount_mode(chunk) == "zeroing"):
            chunks.append(chunk)
    return chunks


def _amount_mode(text: str) -> str:
    normalized = _normalize_text(text)
    if re.search(r"\bперенест[а-я]*\b", normalized) and re.search(r"\bс\s+20\d{2}\b", normalized) and re.search(r"\bна\s+20\d{2}\b", normalized):
        return "transfer"
    if re.search(r"\bисключить\b|\bобнулить\b|снять лимит|финансировани[ея]\s+не\s+предусмотр", normalized):
        return "zeroing"
    if re.search(r"увеличить\s+на|добавить|дополнительно|увеличение\s+на", normalized):
        return "delta_plus"
    if re.search(r"уменьшить\s+на|сократить\s+на|снижение\s+на", normalized):
        return "delta_minus"
    if re.search(r"увеличить\s+с\b.*\bдо\b|уменьшить\s+с\b.*\bдо\b", normalized):
        return "absolute"
    if re.search(r"предусмотреть|установить|составляет|в размере|до\s+\d", normalized):
        return "absolute"
    return "unknown"


def _extract_amounts(text: str) -> List[Decimal]:
    amounts: list[Decimal] = []
    for match in MONEY_RE.finditer(text):
        unit = "thousand_rub" if match.group("thousand") else "rub"
        amounts.append(parse_money_to_rub(match.group("value"), unit=unit))
    return amounts


def _extract_object_name(text: str) -> str | None:
    quoted = QUOTED_OBJECT_RE.search(text)
    if quoted:
        return _clean_object_name(quoted.group("object"))

    plain = PLAIN_OBJECT_RE.search(text)
    if plain:
        return _clean_object_name(plain.group("object"))

    return None


def _clean_object_name(value: str) -> str:
    value = re.sub(r"[\u00a0\u202f\s]+", " ", value).strip(" ,.;:-")
    return value[:240]


def _normalize_text(text: str) -> str:
    text = text.lower().replace("ё", "е")
    text = text.replace("_x000d_", " ")
    return re.sub(r"[\u00a0\u202f\s]+", " ", text).strip()


def _trim_evidence(text: str, limit: int = 500) -> str:
    text = re.sub(r"[\u00a0\u202f\s]+", " ", text).strip()
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0].strip()


def _confidence(*, object_name: str, source: BudgetSource, old_amount: Decimal | None, amount_count: int, mode: str) -> float:
    confidence = Decimal("0.45")
    if object_name:
        confidence += Decimal("0.20")
    if source is not BudgetSource.UNKNOWN:
        confidence += Decimal("0.15")
    if amount_count:
        confidence += Decimal("0.10")
    if old_amount is not None:
        confidence += Decimal("0.05")
    if mode in {"absolute", "delta_plus", "delta_minus", "transfer"}:
        confidence += Decimal("0.05")
    if mode in {"zeroing", "unknown"}:
        confidence -= Decimal("0.15")
    return float(min(confidence, Decimal("0.95")))


def _decimal_to_text(value: Decimal) -> str:
    return quantize_rub(value).to_eng_string()
