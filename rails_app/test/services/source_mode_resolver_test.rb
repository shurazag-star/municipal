require "test_helper"

class SourceModeResolverTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "source-mode@example.com")
    @organization = @user.organization
  end

  test "uses latest Excel as calculation source and PDFs as evidence when both are present" do
    old_excel = source_document!("xlsx_finance", "Старые финансы.xlsx")
    latest_excel = source_document!("xlsx_finance", "Новые финансы.xlsx")
    pdf = source_document!("pdf_agreement", "Соглашение.pdf")

    resolver = SourceModeResolver.new(organization: @organization)

    assert_equal "xlsx_target_with_pdf_evidence", resolver.mode
    assert_equal [latest_excel.id], resolver.calculation_documents.map(&:id)
    assert_equal [pdf.id], resolver.evidence_documents.map(&:id)
    assert_not_includes resolver.available_documents.map(&:id), old_excel.id
  end

  test "uses PDFs only in pdf patch mode" do
    source_document!("xlsx_finance", "Финансы.xlsx")
    pdf = source_document!("pdf_agreement", "Соглашение.pdf")

    resolver = SourceModeResolver.new(organization: @organization, requested_mode: "pdf_patch")

    assert_equal "pdf_patch", resolver.mode
    assert_equal [pdf.id], resolver.calculation_documents.map(&:id)
    assert_empty resolver.evidence_documents
  end

  test "honors organization default source mode" do
    source_document!("xlsx_finance", "Финансы.xlsx")
    pdf = source_document!("pdf_agreement", "Соглашение.pdf")
    @organization.update!(settings: { "default_source_mode" => "pdf_patch" })

    resolver = SourceModeResolver.new(organization: @organization)

    assert_equal "pdf_patch", resolver.mode
    assert_equal [pdf.id], resolver.calculation_documents.map(&:id)
  end

  test "supports manual instruction mode without file calculation sources" do
    source_document!("xlsx_finance", "Финансы.xlsx")
    source_document!("pdf_agreement", "Соглашение.pdf")

    resolver = SourceModeResolver.new(organization: @organization, requested_mode: "manual_instruction")

    assert_equal "manual_instruction", resolver.mode
    assert_empty resolver.calculation_documents
    assert_empty resolver.evidence_documents
    assert_equal "Ручной ввод в чате", resolver.label
    assert_equal "manual_instruction", resolver.summary["source_mode"]
  end

  private

  def source_document!(document_type, filename)
    SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: document_type,
      filename: filename,
      status: "parsed",
      parsed_payload: {}
    )
  end
end
