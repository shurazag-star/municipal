require "test_helper"

class MultiTenantAccessTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_isolated_user!(email: "tenant-a@example.com")
    @other_user = create_isolated_user!(email: "tenant-b@example.com")
    @other_document = SourceDocument.create!(
      organization: @other_user.organization,
      created_by: @other_user,
      document_type: "docx_program",
      filename: "Чужая программа.docx",
      status: "parsed",
      parsed_payload: {}
    )
    post session_path, params: { email: @user.email, password: "password123" }
  end

  test "user cannot open another organization source document" do
    get source_document_path(@other_document)

    assert_response :not_found
  end
end
