from __future__ import annotations

from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
import re
from typing import Any


RUB_QUANT = Decimal("0.01")


def quantize_rub(value: Decimal) -> Decimal:
    return value.quantize(RUB_QUANT, rounding=ROUND_HALF_UP)


def parse_money_to_rub(value: Any, unit: str = "rub") -> Decimal:
    """Parse Russian-formatted money into rubles.

    Internal storage is always rubles with two decimal places.
    """
    if value is None:
        amount = Decimal("0")
    elif isinstance(value, Decimal):
        amount = value
    elif isinstance(value, (int, float)):
        amount = Decimal(str(value))
    else:
        text = str(value).strip()
        if not text or text in {"-", "—"}:
            amount = Decimal("0")
        else:
            text = text.replace("\u00a0", " ").replace("\u202f", " ")
            text = re.sub(r"(руб\.?|тыс\.?|₽)", "", text, flags=re.IGNORECASE)
            text = text.replace(" ", "").replace(",", ".")
            try:
                amount = Decimal(text)
            except InvalidOperation as exc:
                raise ValueError(f"Cannot parse money value: {value!r}") from exc

    if unit == "thousand_rub":
        amount *= Decimal("1000")
    elif unit != "rub":
        raise ValueError(f"Unknown money unit: {unit}")

    return quantize_rub(amount)


def rub_to_thousand(amount_rub: Decimal) -> Decimal:
    return quantize_rub(amount_rub / Decimal("1000"))

