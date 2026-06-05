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

  test "Lyubertsy and Shatura employees keep documents and agent settings separated" do
    lyubertsy_employee = create_isolated_user!(
      email: "employee-lyubertsy@example.com",
      password: "1111",
      role: "user"
    )
    lyubertsy = lyubertsy_employee.organization
    lyubertsy.update!(
      name: "Городской округ Люберцы",
      municipality_name: "Городского округа Люберцы",
      settings: { "tenant_key" => "lyubertsy", "default_source_mode" => "auto" }
    )
    shatura_employee = create_isolated_user!(
      email: "employee-shatura-isolated@example.com",
      password: "2222",
      role: "user"
    )
    shatura = shatura_employee.organization
    shatura.update!(
      name: "Муниципальный округ Шатура",
      municipality_name: "Муниципального округа Шатура",
      settings: { "tenant_key" => "shatura", "default_source_mode" => "auto" }
    )
    AgentSetting.for_organization!(lyubertsy).update!(system_prompt: "Люберцы: отдельная инструкция")
    AgentSetting.for_organization!(shatura).update!(system_prompt: "Шатура: отдельная инструкция")

    SourceDocument.create!(
      organization: lyubertsy,
      created_by: lyubertsy_employee,
      document_type: "docx_program",
      filename: "Программа Люберцы.docx",
      status: "parsed",
      parsed_payload: { "program" => { "name" => "Программа Люберцы" } }
    )
    SourceDocument.create!(
      organization: shatura,
      created_by: shatura_employee,
      document_type: "docx_program",
      filename: "Программа Шатура.docx",
      status: "parsed",
      parsed_payload: { "program" => { "name" => "Программа Шатура" } }
    )

    delete session_path
    post session_path, params: { email: lyubertsy_employee.email, password: "1111" }
    get employee_workspace_path

    assert_response :success
    assert_includes @response.body, "Программа Люберцы.docx"
    assert_not_includes @response.body, "Программа Шатура.docx"
    assert_equal "auto", SourceModeResolver.new(organization: lyubertsy).requested_mode
    assert_equal "Люберцы: отдельная инструкция", AgentSetting.for_organization!(lyubertsy).system_prompt

    delete session_path
    post session_path, params: { email: shatura_employee.email, password: "2222" }
    get employee_workspace_path

    assert_response :success
    assert_includes @response.body, "Программа Шатура.docx"
    assert_not_includes @response.body, "Программа Люберцы.docx"
    assert_equal "auto", SourceModeResolver.new(organization: shatura).requested_mode
    assert_equal "Шатура: отдельная инструкция", AgentSetting.for_organization!(shatura).system_prompt
  end
end
