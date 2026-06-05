require "test_helper"

class ExternalTargetSourceTotalResolverTest < ActiveSupport::TestCase
  setup do
    @organization = create_isolated_user!(email: "source-total-resolver@example.com").organization
  end

  test "reconciles object group source totals to final yearly totals through local budget" do
    totals = ExternalTargetSourceTotalResolver.new(
      payload: {
        "final_totals" => { "2026" => "100.00" },
        "object_groups" => [
          { "funding" => { "2026::REGIONAL_BUDGET" => "80.00" } },
          { "funding" => { "2026::LOCAL_BUDGET" => "30.00" } }
        ]
      },
      organization: @organization,
      tolerance: "0.01"
    ).source_year_totals

    assert_equal BigDecimal("80.00"), totals[[2026, "REGIONAL_BUDGET"]]
    assert_equal BigDecimal("20.00"), totals[[2026, "LOCAL_BUDGET"]]
  end
end
