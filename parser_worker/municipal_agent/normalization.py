from __future__ import annotations

import re


ZERO_WIDTH_RE = re.compile(r"[\u200b\u200c\u200d\ufeff]")


def normalize_name(raw_name: object) -> str:
    text = "" if raw_name is None else str(raw_name)
    text = ZERO_WIDTH_RE.sub("", text)
    text = text.lower().replace("ё", "е")
    text = text.replace("\u00a0", " ").replace("\u202f", " ")
    text = re.sub(r"\bв\s+том\s+числе\b", "в т.ч.", text)
    text = re.sub(r"\bг\.\s*о\.", "городской округ", text)
    text = re.sub(r"\bм\.\s*о\.", "муниципальный округ", text)
    text = re.sub(r"\bр\.\s*п\.", "рабочий поселок", text)
    text = re.sub(r"\bп\.", "поселок", text)
    text = re.sub(r"\bс\.", "село", text)
    text = re.sub(r"\bд\.", "деревня", text)
    text = re.sub(r"\bпир\s+и\s+тп\b", "пир и тп", text)
    text = re.sub(r"[«»“”\"(),;:]", " ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()

