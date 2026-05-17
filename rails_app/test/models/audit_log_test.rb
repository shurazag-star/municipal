require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  test "record stores polymorphic auditable target" do
    user = create_user!
    document = SourceDocument.create!(
      organization: user.organization,
      created_by: user,
      document_type: "docx_program",
      filename: "program.docx",
      status: "uploaded"
    )

    log = AuditLog.record!(user, user.organization, "source_document.uploaded", document, filename: document.filename)

    assert_equal document, log.auditable
    assert_equal "source_document.uploaded", log.action
    assert_equal "program.docx", log.payload["filename"]
  end
end
