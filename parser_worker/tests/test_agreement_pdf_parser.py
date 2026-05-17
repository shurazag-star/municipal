from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from municipal_agent import agreement_pdf_parser
from municipal_agent.agreement_pdf_parser import extract_agreement_changes_from_pages, parse_pdf_agreement
from pypdf import PdfWriter


PARSER_ROOT = Path(__file__).resolve().parents[1]
CLI = PARSER_ROOT / "cli.py"


def test_extracts_agreement_change_from_pdf_text_window():
    pages = [
        {
            "page_number": 3,
            "text": (
                "Министерство сообщает: по объекту «ВЗУ Черусти» на 2028 год "
                "средства бюджета Московской области увеличить с 690 689,18 тыс. рублей "
                "до 780 689,18 тыс. рублей."
            ),
        }
    ]

    changes = extract_agreement_changes_from_pages(pages)

    assert len(changes) == 1
    change = changes[0]
    assert change.object_name == "ВЗУ Черусти"
    assert change.year == 2028
    assert change.source_type == "REGIONAL_BUDGET"
    assert change.old_amount_rub == "690689180.00"
    assert change.amount_rub == "780689180.00"
    assert change.delta_rub == "90000000.00"
    assert change.page_number == 3
    assert "ВЗУ Черусти" in change.evidence_text
    assert change.confidence >= 0.8
    assert change.amount_mode == "absolute"


def test_extracts_delta_plus_mode_from_agreement_text():
    pages = [
        {
            "page_number": 1,
            "text": "По объекту «ВЗУ Черусти» на 2028 год увеличить на 10 000 000 рублей средства бюджета Московской области.",
        }
    ]

    changes = extract_agreement_changes_from_pages(pages)

    assert len(changes) == 1
    assert changes[0].amount_mode == "delta_plus"
    assert changes[0].delta_rub == "10000000.00"
    assert changes[0].new_amount_rub is None


def test_extracts_delta_minus_mode_from_agreement_text():
    pages = [
        {
            "page_number": 1,
            "text": "По объекту «ВЗУ Черусти» на 2027 год уменьшить на 5 000 000 рублей средства местного бюджета.",
        }
    ]

    changes = extract_agreement_changes_from_pages(pages)

    assert len(changes) == 1
    assert changes[0].amount_mode == "delta_minus"
    assert changes[0].delta_rub == "-5000000.00"


def test_extracts_transfer_mode_between_years():
    pages = [
        {
            "page_number": 2,
            "text": "По объекту «ВЗУ Черусти» перенести 7 000 000 рублей с 2026 года на 2027 год.",
        }
    ]

    changes = extract_agreement_changes_from_pages(pages)

    assert len(changes) == 1
    assert changes[0].amount_mode == "transfer"
    assert changes[0].from_year == 2026
    assert changes[0].to_year == 2027
    assert changes[0].delta_rub == "7000000.00"


def test_extracts_zeroing_mode_without_amount():
    pages = [
        {
            "page_number": 4,
            "text": "По объекту «ВЗУ Черусти» на 2028 год исключить финансирование из средств местного бюджета.",
        }
    ]

    changes = extract_agreement_changes_from_pages(pages)

    assert len(changes) == 1
    assert changes[0].amount_mode == "zeroing"
    assert changes[0].new_amount_rub == "0.00"
    assert changes[0].confidence < 0.8


def test_extracts_appendix_budget_table_from_positioned_text():
    positioned_pages = [
        {
            "page_number": 6,
            "items": [
                {"x": 61.2, "y": 522.4, "text": "Капитальный ремонт се"},
                {"x": 61.2, "y": 510.4, "text": "тей водоснабжения, во"},
                {"x": 61.2, "y": 498.4, "text": "доотведения"},
                {"x": 172.0, "y": 522.4, "text": "Капитальный ремонт сетей ВС, г.о. Шатура (1 этап)"},
                {"x": 424.9, "y": 446.7, "text": "Всего"},
                {"x": 595.0, "y": 522.4, "text": "10"},
                {"x": 595.0, "y": 510.4, "text": "00"},
                {"x": 595.0, "y": 498.4, "text": "00"},
                {"x": 595.0, "y": 486.4, "text": "00"},
                {"x": 597.5, "y": 474.4, "text": "0,"},
                {"x": 595.0, "y": 462.4, "text": "00"},
                {"x": 612.3, "y": 522.4, "text": "25"},
                {"x": 612.3, "y": 510.4, "text": "87"},
                {"x": 612.3, "y": 498.4, "text": "50"},
                {"x": 612.3, "y": 486.4, "text": "60"},
                {"x": 768.6, "y": 522.4, "text": "15"},
                {"x": 768.6, "y": 510.4, "text": "60"},
                {"x": 768.6, "y": 498.4, "text": "69"},
                {"x": 766.0, "y": 486.4, "text": "40"},
                {"x": 776.2, "y": 486.4, "text": ","},
                {"x": 768.6, "y": 474.4, "text": "0"},
                {"x": 773.7, "y": 474.4, "text": "0"},
                {"x": 785.2, "y": 522.4, "text": "40"},
                {"x": 785.2, "y": 510.4, "text": "38"},
                {"x": 785.2, "y": 498.4, "text": "31"},
                {"x": 790.3, "y": 486.4, "text": "0"},
            ],
        }
    ]

    changes = agreement_pdf_parser._extract_budget_table_changes_from_positioned_pages(positioned_pages)

    by_key = {(change.year, change.source_type): change for change in changes}
    assert by_key[(2026, "REGIONAL_BUDGET")].amount_rub == "100000000.00"
    assert by_key[(2027, "REGIONAL_BUDGET")].amount_rub == "25875060.00"
    assert by_key[(2026, "LOCAL_BUDGET")].amount_rub == "15606940.00"
    assert by_key[(2027, "LOCAL_BUDGET")].amount_rub == "4038310.00"
    assert by_key[(2026, "REGIONAL_BUDGET")].event_name == "Капитальный ремонт сетей водоснабжения, водоотведения"
    assert "Капитальный ремонт сетей ВС" in by_key[(2026, "REGIONAL_BUDGET")].object_name


def test_extracts_multirow_appendix_budget_table_from_continued_page():
    positioned_pages = [
        {
            "page_number": 9,
            "items": [
                {"x": 61.2, "y": 525.4, "text": "Строительство (реконст"},
                {"x": 61.2, "y": 513.4, "text": "рукция) канализацион"},
                {"x": 61.2, "y": 501.4, "text": "ных коллекторов, кана"},
                {"x": 61.2, "y": 489.4, "text": "лизационных насосных"},
                {"x": 61.2, "y": 477.4, "text": "станций муниципальной"},
                {"x": 61.2, "y": 465.4, "text": "собственности"},
                {"x": 172.0, "y": 522.4, "text": "Реконструкция КНС № 1 ул. 3-го Интерн"},
                {"x": 172.0, "y": 510.4, "text": "ационала м.о. Шату"},
                {"x": 172.0, "y": 486.4, "text": "ра (в т.ч. ПИР)"},
                {"x": 412.5, "y": 522.4, "text": "01"},
                {"x": 526.9, "y": 522.4, "text": "12506660"},
                {"x": 554.9, "y": 510.4, "text": ",00"},
                {"x": 572.6, "y": 522.4, "text": "88438240"},
                {"x": 600.6, "y": 510.4, "text": ",00"},
                {"x": 712.2, "y": 522.4, "text": "2914620,"},
                {"x": 740.2, "y": 510.4, "text": "00"},
                {"x": 757.2, "y": 522.4, "text": "5645000,"},
                {"x": 785.2, "y": 510.4, "text": "00"},
                {"x": 172.0, "y": 458.7, "text": "Реконструкция КНС № 2 на ул. 1-ая Перв"},
                {"x": 172.0, "y": 446.7, "text": "омайская м.о. Шату"},
                {"x": 172.0, "y": 422.7, "text": "ра (в т.ч. ПИР)"},
                {"x": 412.5, "y": 458.7, "text": "02"},
                {"x": 549.8, "y": 458.7, "text": "0,00"},
                {"x": 572.6, "y": 458.7, "text": "76801180"},
                {"x": 600.6, "y": 446.7, "text": ",00"},
                {"x": 732.6, "y": 458.7, "text": "0,00"},
                {"x": 754.7, "y": 458.7, "text": "17898180"},
                {"x": 782.6, "y": 446.7, "text": ",00"},
                {"x": 172.0, "y": 394.9, "text": "Реконструкция КНС № 4 на ул. Советская"},
                {"x": 172.0, "y": 382.9, "text": "м.о. Шатура"},
                {"x": 172.0, "y": 370.9, "text": "(в т.ч. ПИР)"},
                {"x": 412.5, "y": 394.9, "text": "03"},
                {"x": 549.8, "y": 394.9, "text": "0,00"},
                {"x": 572.6, "y": 394.9, "text": "69293350"},
                {"x": 600.6, "y": 382.9, "text": ",00"},
                {"x": 732.6, "y": 394.9, "text": "0,00"},
                {"x": 754.7, "y": 394.9, "text": "16148520"},
                {"x": 782.6, "y": 382.9, "text": ",00"},
                {"x": 406.4, "y": 331.2, "text": "Всего"},
            ],
        }
    ]

    changes = agreement_pdf_parser._extract_budget_table_changes_from_positioned_pages(positioned_pages)

    by_object = {
        (change.object_name, change.year, change.source_type): change
        for change in changes
    }
    kns1 = "Реконструкция КНС № 1 ул. 3-го Интернационала м.о. Шатура (в т.ч. ПИР)"
    kns2 = "Реконструкция КНС № 2 на ул. 1-ая Первомайская м.о. Шатура (в т.ч. ПИР)"
    kns4 = "Реконструкция КНС № 4 на ул. Советская м.о. Шатура (в т.ч. ПИР)"
    assert by_object[(kns1, 2026, "REGIONAL_BUDGET")].amount_rub == "12506660.00"
    assert by_object[(kns1, 2027, "LOCAL_BUDGET")].amount_rub == "5645000.00"
    assert by_object[(kns2, 2026, "REGIONAL_BUDGET")].amount_rub == "0.00"
    assert by_object[(kns2, 2027, "REGIONAL_BUDGET")].amount_rub == "76801180.00"
    assert by_object[(kns4, 2027, "LOCAL_BUDGET")].amount_rub == "16148520.00"
    assert by_object[(kns4, 2027, "LOCAL_BUDGET")].event_name == (
        "Строительство (реконструкция) канализационных коллекторов, "
        "канализационных насосных станций муниципальной собственности"
    )


def test_profiles_detected_pdf_table_and_validates_control_sums():
    analysis = agreement_pdf_parser._analyze_budget_tables_from_positioned_pages(_control_sum_positioned_pages())

    assert analysis["control_sums"]["status"] == "passed"
    assert analysis["control_sums"]["checked_table_count"] == 1
    table = analysis["tables"][0]
    assert table["table_type"] == "continued_appendix_budget_table"
    assert table["row_count"] == 2
    assert table["columns"]["2026::REGIONAL_BUDGET"] == {"min_x": 520.0, "max_x": 570.0}


def test_marks_pdf_table_profile_failed_when_total_row_does_not_match_details():
    positioned_pages = _control_sum_positioned_pages()
    for item in positioned_pages[0]["items"]:
        if item["text"] == "15,00":
            item["text"] = "16,00"
            break

    analysis = agreement_pdf_parser._analyze_budget_tables_from_positioned_pages(positioned_pages)

    assert analysis["control_sums"]["status"] == "failed"
    failed = [check for check in analysis["control_sums"]["checks"] if check["status"] == "failed"]
    assert failed[0]["source_type"] == "REGIONAL_BUDGET"
    assert failed[0]["difference_rub"] == "-1.00"


def test_parse_agreement_pdf_cli_outputs_valid_empty_schema_for_non_agreement_pdf(tmp_path):
    blank_pdf = tmp_path / "blank.pdf"
    writer = PdfWriter()
    writer.add_blank_page(width=612, height=792)
    writer.write(blank_pdf)

    completed = subprocess.run(
        [sys.executable, str(CLI), "parse-agreement-pdf", str(blank_pdf)],
        cwd=PARSER_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )

    payload = json.loads(completed.stdout)
    assert payload["document_type"] == "pdf_agreement"
    assert isinstance(payload["changes"], list)
    assert isinstance(payload["warnings"], list)
    assert payload["page_count"] > 0


def test_parse_agreement_pdf_uses_ocr_when_text_layer_is_empty(monkeypatch, tmp_path):
    blank_pdf = tmp_path / "scan.pdf"
    writer = PdfWriter()
    writer.add_blank_page(width=612, height=792)
    writer.write(blank_pdf)

    def fake_ocr_pages(path, page_count):
        return [
            {
                "page_number": 1,
                "text": (
                    "По объекту «ВЗУ Черусти» на 2028 год средства бюджета Московской области "
                    "увеличить с 690 689,18 тыс. рублей до 780 689,18 тыс. рублей."
                ),
                "normalized_text": "",
                "extraction_method": "ocr",
            }
        ]

    monkeypatch.setattr(agreement_pdf_parser, "_ocr_pages", fake_ocr_pages)

    payload = parse_pdf_agreement(blank_pdf)

    assert payload.text_extraction_method == "ocr"
    assert payload.changes[0].object_name == "ВЗУ Черусти"
    assert payload.changes[0].amount_rub == "780689180.00"
    assert any("OCR" in warning for warning in payload.warnings)


def _control_sum_positioned_pages():
    return [
        {
            "page_number": 9,
            "items": [
                {"x": 61.2, "y": 520.0, "text": "Строительство канализационных насосных"},
                {"x": 61.2, "y": 508.0, "text": "станций муниципальной собственности"},
                {"x": 172.0, "y": 520.0, "text": "Реконструкция КНС № 1"},
                {"x": 412.5, "y": 520.0, "text": "01"},
                {"x": 526.9, "y": 520.0, "text": "10,00"},
                {"x": 712.2, "y": 520.0, "text": "2,00"},
                {"x": 172.0, "y": 470.0, "text": "Реконструкция КНС № 2"},
                {"x": 412.5, "y": 470.0, "text": "02"},
                {"x": 526.9, "y": 470.0, "text": "5,00"},
                {"x": 712.2, "y": 470.0, "text": "3,00"},
                {"x": 406.4, "y": 330.0, "text": "Всего"},
                {"x": 526.9, "y": 330.0, "text": "15,00"},
                {"x": 712.2, "y": 330.0, "text": "5,00"},
            ],
        }
    ]
