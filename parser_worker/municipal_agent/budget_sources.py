from __future__ import annotations

from enum import Enum
import re


class BudgetSource(str, Enum):
    FEDERAL_BUDGET = "FEDERAL_BUDGET"
    REGIONAL_BUDGET = "REGIONAL_BUDGET"
    MOSCOW_OBLAST_BUDGET = "REGIONAL_BUDGET"
    MOSCOW_CITY_BUDGET = "REGIONAL_BUDGET"
    LOCAL_BUDGET = "LOCAL_BUDGET"
    MUNICIPAL_BUDGET = "MUNICIPAL_BUDGET"
    EXTRABUDGETARY = "EXTRABUDGETARY"
    PRIVATE_FUNDS = "PRIVATE_FUNDS"
    OTHER_SOURCE = "OTHER_SOURCE"
    UNKNOWN = "UNKNOWN"


def _norm(text: str) -> str:
    text = text.lower().replace("ё", "е")
    text = re.sub(r"[\u00a0\u202f\s]+", " ", text)
    return text.strip()


def normalize_budget_source(raw_name: object) -> BudgetSource:
    text = _norm("" if raw_name is None else str(raw_name))
    if not text:
        return BudgetSource.UNKNOWN
    if "федерал" in text:
        return BudgetSource.FEDERAL_BUDGET
    if re.search(r"собственн.*бюджет", text):
        return BudgetSource.LOCAL_BUDGET
    if re.search(r"инвестор|концессион|частн|собственн.*средств", text):
        return BudgetSource.PRIVATE_FUNDS
    if "внебюдж" in text:
        return BudgetSource.EXTRABUDGETARY
    if re.search(r"иные? источник|прочие? источник", text):
        return BudgetSource.OTHER_SOURCE
    if re.search(r"местн|муниципальн.*округ|городск.*округ|муниципальн.*образован|поселен", text):
        return BudgetSource.LOCAL_BUDGET
    if re.search(r"муниципальн.*район|муниципальн.*бюджет", text):
        return BudgetSource.MUNICIPAL_BUDGET
    if re.search(r"московск|субъект|област|краев|республикан|региональн|ленинградск", text):
        return BudgetSource.REGIONAL_BUDGET
    if "средства бюджета" in text:
        return BudgetSource.LOCAL_BUDGET
    return BudgetSource.UNKNOWN


SOURCE_LABELS = {
    BudgetSource.FEDERAL_BUDGET: "Средства федерального бюджета",
    BudgetSource.REGIONAL_BUDGET: "Средства бюджета субъекта РФ",
    BudgetSource.LOCAL_BUDGET: "Средства бюджета муниципального округа",
    BudgetSource.MUNICIPAL_BUDGET: "Средства муниципального бюджета",
    BudgetSource.EXTRABUDGETARY: "Внебюджетные средства",
    BudgetSource.PRIVATE_FUNDS: "Частные средства",
    BudgetSource.OTHER_SOURCE: "Иные источники",
    BudgetSource.UNKNOWN: "Не распознано",
}
