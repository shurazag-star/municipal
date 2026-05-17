from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import re
from typing import Dict, List

from pypdf import PdfReader


@dataclass
class ParsedProcedurePdf:
    page_count: int
    text_char_count: int
    normalized_text: str
    rules: List[str] = field(default_factory=list)
    pages: List[Dict[str, str | int]] = field(default_factory=list)
    chunks: List[Dict[str, object]] = field(default_factory=list)


CHUNK_DEFINITIONS = [
    (
        "procedure_general",
        "Общие положения",
        ("муницип", "планирован", "порядок", "постановлен"),
    ),
    (
        "program_structure",
        "Структура муниципальной программы",
        ("структур", "паспорт", "подпрограмм", "мероприят"),
    ),
    (
        "indicators_and_results",
        "Показатели и результаты",
        ("показател", "результат", "эффективност", "методик"),
    ),
    (
        "change_procedure",
        "Порядок внесения изменений",
        ("изменени", "основан", "проект изменений", "корректиров"),
    ),
    (
        "approval_terms",
        "Согласование и сроки",
        ("согласован", "5 рабочих дней", "срок", "не позднее"),
    ),
    (
        "forms",
        "Формы и приложения",
        ("форма", "приложени", "перечн", "адресн"),
    ),
    (
        "reporting",
        "Отчетность",
        ("отчет", "мониторинг", "годов", "реализаци"),
    ),
]


def parse_pdf_procedure(path: str | Path) -> ParsedProcedurePdf:
    reader = PdfReader(str(path))
    raw_pages = [page.extract_text() or "" for page in reader.pages]
    pages = [
        {
            "page_number": index,
            "text": raw_text.strip(),
            "normalized_text": _normalize_pdf_text(raw_text),
        }
        for index, raw_text in enumerate(raw_pages, start=1)
    ]
    raw_text = "\n".join(raw_pages)
    normalized_text = _normalize_pdf_text(raw_text)
    rules = _extract_rules(normalized_text)
    chunks = _extract_chunks(pages, normalized_text, rules)
    return ParsedProcedurePdf(
        page_count=len(reader.pages),
        text_char_count=len(raw_text),
        normalized_text=normalized_text,
        rules=rules,
        pages=pages,
        chunks=chunks,
    )


def _normalize_pdf_text(text: str) -> str:
    text = text.lower().replace("ё", "е")
    text = text.replace("_x000d_", " ")
    text = text.replace("контроlьно", "контрольно")
    text = text.replace("па.пат", "палат")
    text = text.replace("муниципаjiь", "муниципаль")
    text = text.replace("муниципаjь", "муниципаль")
    text = text.replace("муниципaль", "муниципаль")
    text = text.replace("прогрtl", "програ")
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def _extract_rules(text: str) -> List[str]:
    rules: List[str] = []
    if "муницип" in text and "планирован" in text:
        rules.append("Муниципальная программа является документом стратегического планирования")
    if "проект изменений" in text and "контрольно-счетной палат" in text and "не подлежит" in text:
        rules.append("Проект изменений не требует согласования с Контрольно-счетной палатой")
    if "5 рабочих дней" in text and "проект" in text:
        rules.append("Согласование проекта выполняется в течение 5 рабочих дней")
    if "не позднее 1 марта" in text:
        rules.append("После финансового года корректировка плановых значений допускается не позднее 1 марта")
    return rules


def _extract_chunks(pages: List[Dict[str, str | int]], normalized_text: str, rules: List[str]) -> List[Dict[str, object]]:
    chunks: List[Dict[str, object]] = []
    fallback = _trim_chunk_content(" ".join(rules) or normalized_text)
    for chunk_type, title, keywords in CHUNK_DEFINITIONS:
        matched_pages = [
            page
            for page in pages
            if any(keyword in str(page["normalized_text"]) for keyword in keywords)
        ]
        content = _content_from_pages(matched_pages)
        if not content:
            content = fallback

        chunks.append(
            {
                "chunk_type": chunk_type,
                "title": title,
                "content": content,
                "page_number": matched_pages[0]["page_number"] if matched_pages else None,
                "metadata": {
                    "keywords": list(keywords),
                    "matched_page_count": len(matched_pages),
                },
            }
        )
    return chunks


def _content_from_pages(pages: List[Dict[str, str | int]]) -> str:
    if not pages:
        return ""

    content = " ".join(str(page["normalized_text"]) for page in pages[:3])
    return _trim_chunk_content(content)


def _trim_chunk_content(content: str, limit: int = 2200) -> str:
    content = re.sub(r"\s+", " ", content).strip()
    if len(content) <= limit:
        return content
    return content[:limit].rsplit(" ", 1)[0].strip()
