from municipal_agent.budget_sources import BudgetSource, normalize_budget_source


def test_normalizes_universal_regional_budget_aliases():
    assert normalize_budget_source("Средства краевого бюджета") == BudgetSource.REGIONAL_BUDGET
    assert normalize_budget_source("республиканский бюджет") == BudgetSource.REGIONAL_BUDGET
    assert normalize_budget_source("бюджет субъекта РФ") == BudgetSource.REGIONAL_BUDGET


def test_legacy_moscow_constants_are_regional_aliases():
    assert BudgetSource.MOSCOW_OBLAST_BUDGET == BudgetSource.REGIONAL_BUDGET
    assert BudgetSource.MOSCOW_CITY_BUDGET == BudgetSource.REGIONAL_BUDGET
    assert normalize_budget_source("бюджет Московской области") == BudgetSource.REGIONAL_BUDGET


def test_normalizes_private_and_other_sources():
    assert normalize_budget_source("средства инвестора") == BudgetSource.PRIVATE_FUNDS
    assert normalize_budget_source("концессионер") == BudgetSource.PRIVATE_FUNDS
    assert normalize_budget_source("иные источники") == BudgetSource.OTHER_SOURCE


def test_normalizes_own_budget_columns_as_local_budget():
    assert normalize_budget_source("средства собственного бюджета на 2 год планового периода") == BudgetSource.LOCAL_BUDGET
    assert normalize_budget_source("средства собственного бюджета на 3 год планового периода") == BudgetSource.LOCAL_BUDGET


def test_normalizes_named_municipality_budget_as_local_budget():
    assert normalize_budget_source("Средства бюджета Шатура") == BudgetSource.LOCAL_BUDGET
    assert normalize_budget_source("Средства бюджета муниципального округа Шатура Московской области") == BudgetSource.LOCAL_BUDGET
