from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[2]
CLI = PROJECT_ROOT / "parser_worker" / "cli.py"
DOCX = PROJECT_ROOT / "sample_documents" / "проект изменений МП_март_2026 (10).docx"
XLSX = PROJECT_ROOT / "sample_documents" / "Отчет_о_финансировании_мероприятий_целевых_программ+_Расширенный.xlsx"
pytestmark = pytest.mark.skipif(
    not DOCX.exists() or not XLSX.exists(),
    reason="real sample documents are not committed to the deploy repository",
)


def test_parse_docx_cli_outputs_json_for_real_document():
    payload = _run_json("parse-docx", DOCX)

    assert payload["passport_totals_by_year"]["2026"] == "2296101960.00"
    assert len(payload["subprograms"]) == 8
    assert len(payload["nodes"]) > 100
    assert len(payload["funding_lines"]) > 100
    assert any(node["node_type"] == "object" and "Черусти" in node["name"] for node in payload["nodes"])
    assert all("source_cell_index" in line for line in payload["funding_lines"])


def test_parse_xlsx_cli_outputs_json_for_real_document():
    payload = _run_json("parse-xlsx", XLSX)

    assert payload["program_totals"]["2026"] == "2253220255.91"
    assert payload["sheet_name"] == "Результат"


def _run_json(command: str, path: Path) -> dict:
    completed = subprocess.run(
        [sys.executable, str(CLI), command, str(path)],
        cwd=PROJECT_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)
