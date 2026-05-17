require "test_helper"

class FundingSourceCatalogTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "funding-source-catalog@example.com")
    @organization = @user.organization
  end

  test "normalizes regional labels from different municipality types" do
    assert_equal "REGIONAL_BUDGET", FundingSourceCatalog.normalize("Средства краевого бюджета", organization: @organization)
    assert_equal "REGIONAL_BUDGET", FundingSourceCatalog.normalize("республиканский бюджет", organization: @organization)
    assert_equal "REGIONAL_BUDGET", FundingSourceCatalog.normalize("бюджет субъекта Российской Федерации", organization: @organization)
  end

  test "maps legacy Moscow source constants to universal canonical keys" do
    assert_equal "REGIONAL_BUDGET", FundingSourceCatalog.normalize("MOSCOW_OBLAST_BUDGET", organization: @organization)
    assert_equal "REGIONAL_BUDGET", FundingSourceCatalog.normalize("MOSCOW_CITY_BUDGET", organization: @organization)
  end

  test "uses organization aliases for private and other funding" do
    FundingSourceAlias.create!(
      organization: @organization,
      canonical_key: "PRIVATE_FUNDS",
      label: "Средства инвестора",
      aliases: ["средства инвестора", "концессионер"],
      sort_order: 60
    )

    assert_equal "PRIVATE_FUNDS", FundingSourceCatalog.normalize("Концессионер", organization: @organization)
    assert_equal "Средства инвестора", FundingSourceCatalog.label("PRIVATE_FUNDS", organization: @organization)
  end

  test "preserves unknown source as blocking category" do
    assert_equal "UNKNOWN", FundingSourceCatalog.normalize("непонятный источник", organization: @organization)
  end

  test "expands bare municipality name for local budget label" do
    @organization.update!(municipality_name: "Шатура")

    assert_equal "Средства бюджета муниципального округа Шатура", FundingSourceCatalog.label("LOCAL_BUDGET", organization: @organization)
  end

  test "keeps explicit municipality type in local budget label" do
    @organization.update!(municipality_name: "городского округа Тестовый")

    assert_equal "Средства бюджета городского округа Тестовый", FundingSourceCatalog.label("LOCAL_BUDGET", organization: @organization)
  end
end
