require "test_helper"

class ReconciliationBuilderTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "reconciliation-builder@example.com")
    @organization = @user.organization
  end

  test "does not invent a municipal program name when parsed docx has no program name" do
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "program.docx",
      status: "parsed",
      parsed_payload: { "passport_totals_by_year" => { "2026" => "100.00" } }
    )
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "finance.xlsx",
      status: "parsed",
      parsed_payload: { "program_totals" => { "2026" => "100.00" } }
    )

    ReconciliationBuilder.new(organization: @organization, user: @user).refresh!

    assert_equal "Название не определено", @organization.municipal_programs.first.name
  end
end
