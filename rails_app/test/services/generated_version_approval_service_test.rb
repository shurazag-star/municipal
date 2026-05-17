require "test_helper"

class GeneratedVersionApprovalServiceTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "generated-approval@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие инженерной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @active_version = @program.program_versions.create!(
      created_by: @user,
      version_number: 1,
      status: "uploaded_active"
    )
    @program.update!(current_version: @active_version)
    @draft_version = @program.program_versions.create!(
      created_by: @user,
      version_number: 2,
      status: "generated_validated",
      import_summary: { "source_program_version_id" => @active_version.id }
    )
    @change_set = ChangeSet.create!(
      program_version: @active_version,
      target_program_version: @draft_version,
      status: "applied",
      summary: "Проверенный проект новой редакции",
      created_by: @user,
      export_summary: {
        "post_export_validation" => { "status" => "valid" },
        "agent_self_check" => { "status" => "passed" },
        "independent_verifier" => { "status" => "passed" },
        "manual_insert_required_count" => 0
      }
    )
    @change_set.generated_docx_attachment.attach(
      io: StringIO.new("docx"),
      filename: "generated.docx",
      content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    @change_set.change_report_attachment.attach(
      io: StringIO.new("report"),
      filename: "report.html",
      content_type: "text/html"
    )
  end

  test "approves latest validated draft and makes it active" do
    result = GeneratedVersionApprovalService.new(
      organization: @organization,
      user: @user
    ).approve_change_set!(@change_set)

    assert_equal "approved", result["status"]
    assert_equal @draft_version, @program.reload.current_version
    assert_equal "approved_active", @draft_version.reload.status
    assert_equal "archived", @active_version.reload.status
    assert AuditLog.where(action: "generated_version.approved", auditable: @change_set).exists?
  end
end
