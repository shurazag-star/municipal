from __future__ import annotations

import argparse
from dataclasses import asdict, is_dataclass
import json
from decimal import Decimal
from enum import Enum
from pathlib import Path

from municipal_agent.agreement_pdf_parser import parse_pdf_agreement
from municipal_agent.docx_parser import parse_docx_program
from municipal_agent.docx_patcher import patch_docx
from municipal_agent.excel_parser import parse_xlsx_finance_report
from municipal_agent.llm_gateway import explain_mapping_report
from municipal_agent.procedure_pdf_parser import parse_pdf_procedure
from municipal_agent.reports import generate_reconciliation_artifacts


def main() -> None:
    parser = argparse.ArgumentParser(description="Municipal parser worker CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    docx = subparsers.add_parser("parse-docx")
    docx.add_argument("path")

    xlsx = subparsers.add_parser("parse-xlsx")
    xlsx.add_argument("path")

    pdf = subparsers.add_parser("parse-procedure-pdf")
    pdf.add_argument("path")

    agreement_pdf = subparsers.add_parser("parse-agreement-pdf")
    agreement_pdf.add_argument("path")

    report = subparsers.add_parser("generate-report")
    report.add_argument("--docx", required=True)
    report.add_argument("--xlsx", required=True)
    report.add_argument("--pdf", required=True)
    report.add_argument("--out", required=True)

    explain = subparsers.add_parser("explain-report")
    explain.add_argument("--mapping-report", required=True)
    explain.add_argument("--model")
    explain.add_argument("--out")

    patch = subparsers.add_parser("patch-docx")
    patch.add_argument("--input", required=True)
    patch.add_argument("--changes", required=True)
    patch.add_argument("--output", required=True)

    args = parser.parse_args()
    if args.command == "parse-docx":
        payload = parse_docx_program(args.path)
    elif args.command == "parse-xlsx":
        payload = parse_xlsx_finance_report(args.path)
    elif args.command == "parse-procedure-pdf":
        payload = parse_pdf_procedure(args.path)
    elif args.command == "parse-agreement-pdf":
        payload = parse_pdf_agreement(args.path)
    elif args.command == "generate-report":
        payload = generate_reconciliation_artifacts(args.docx, args.xlsx, args.pdf, args.out)
    elif args.command == "explain-report":
        payload = explain_mapping_report(args.mapping_report, model=args.model)
        if args.out:
            Path(args.out).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    elif args.command == "patch-docx":
        changes = json.loads(Path(args.changes).read_text(encoding="utf-8"))
        payload = patch_docx(args.input, args.output, changes)
    else:
        raise SystemExit(f"Unknown command: {args.command}")

    print(json.dumps(_to_jsonable(payload), ensure_ascii=False, indent=2))


def _to_jsonable(value):
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, Path):
        return str(value)
    if is_dataclass(value):
        return _to_jsonable(asdict(value))
    if isinstance(value, dict):
        return {_json_key(key): _to_jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_to_jsonable(item) for item in value]
    if hasattr(value, "__dict__"):
        return _to_jsonable(value.__dict__)
    return value


def _json_key(value):
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, tuple):
        return "::".join(str(_json_key(item)) for item in value)
    return str(value)


if __name__ == "__main__":
    main()
