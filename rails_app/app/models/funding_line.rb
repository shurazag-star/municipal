class FundingLine < ApplicationRecord
  belongs_to :program_node
  belongs_to :source_document, optional: true

  enum :source_type, {
    federal_budget: "FEDERAL_BUDGET",
    regional_budget: "REGIONAL_BUDGET",
    moscow_oblast_budget: "MOSCOW_OBLAST_BUDGET",
    moscow_city_budget: "MOSCOW_CITY_BUDGET",
    local_budget: "LOCAL_BUDGET",
    municipal_budget: "MUNICIPAL_BUDGET",
    extrabudgetary: "EXTRABUDGETARY",
    private_funds: "PRIVATE_FUNDS",
    other_source: "OTHER_SOURCE",
    unknown: "UNKNOWN"
  }

  enum :amount_kind, {
    planned: "planned",
    budget_obligation: "budget_obligation",
    fact: "fact",
    result_plan: "result_plan"
  }, default: "planned"
end
