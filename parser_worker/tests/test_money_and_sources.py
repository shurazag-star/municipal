from decimal import Decimal

from municipal_agent.budget_sources import BudgetSource, normalize_budget_source
from municipal_agent.money import parse_money_to_rub, rub_to_thousand
from municipal_agent.normalization import normalize_name


def test_parses_docx_thousand_rubles_to_rubles_decimal():
    assert parse_money_to_rub("4 853 582,34", unit="thousand_rub") == Decimal("4853582340.00")


def test_parses_money_with_hidden_directional_marks():
    assert parse_money_to_rub("644 395,27\u202c", unit="thousand_rub") == Decimal("644395270.00")


def test_converts_rubles_to_thousand_rubles_for_display():
    assert rub_to_thousand(Decimal("90555380.00")) == Decimal("90555.38")


def test_normalizes_known_budget_source_aliases():
    assert normalize_budget_source("бюджет субъекта РФ / Московской области") == BudgetSource.MOSCOW_OBLAST_BUDGET
    assert normalize_budget_source("Средства федерального бюджета") == BudgetSource.FEDERAL_BUDGET
    assert normalize_budget_source("местный бюджет") == BudgetSource.LOCAL_BUDGET


def test_normalizes_budget_roster_type_codes():
    assert normalize_budget_source("900100") == BudgetSource.LOCAL_BUDGET
    assert normalize_budget_source("900302") == BudgetSource.REGIONAL_BUDGET
    assert normalize_budget_source("900304") == BudgetSource.REGIONAL_BUDGET


def test_normalizes_object_names_for_matching():
    raw = "Строительство ВЗУ\u00a0г.о. Шатура, р.п. Черусти, в том числе ПИР и ТП"
    assert normalize_name(raw) == "строительство взу городской округ шатура рабочий поселок черусти в т.ч. пир и тп"
