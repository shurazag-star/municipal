require "test_helper"

class AnalysisSessionsTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_isolated_user!(email: "analysis-ui@example.com")
    @organization = @user.organization
    @program = MunicipalProgram.create!(
      organization: @organization,
      name: "Развитие инженерной инфраструктуры",
      period_start_year: 2026,
      period_end_year: 2030
    )
    @version = @program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    @program.update!(current_version: @version)
    @node = @version.program_nodes.create!(node_type: "object", name: "ВЗУ Черусти", normalized_name: "взу черусти")
    @node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00")
    @document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {
        "sheet_name" => "Результат",
        "object_groups" => [
          {
            "group_key" => "01::1000004207.1000005123::ВЗУ Черусти",
            "status" => "GROUPED_OBJECT",
            "funding" => { "2026::LOCAL_BUDGET" => "150.00" },
            "rows" => [
              {
                "row_number" => 61,
                "row_type" => "OBJECT_LEAF_ROW",
                "object_code" => "1000004207.1000005123",
                "object_name" => "ВЗУ Черусти",
                "funding" => { "2026::LOCAL_BUDGET" => "150.00" },
                "raw_values" => { "Наименование объекта" => "ВЗУ Черусти" }
              }
            ]
          }
        ]
      }
    )
    login_as(@user)
  end

  test "creates and runs analysis session from selected source documents" do
    assert_difference "AnalysisSession.count", 1 do
      assert_difference "ChangeSet.count", 1 do
        post analysis_sessions_path, params: {
          program_version_id: @version.id,
          selected_source_document_ids: [@document.id],
          goal: "Провести анализ"
        }
      end
    end

    session = AnalysisSession.last
    assert_redirected_to analysis_session_path(session)
    follow_redirect!
    assert_select "h1", "Сессия анализа"
    assert_select "body", /Финансы.xlsx/
    assert_select "body", /Проект изменений/
    assert_select "a[href='#{change_set_path(ChangeSet.last)}']"
  end

  test "does not allow source documents from another organization" do
    other_user = create_isolated_user!(email: "analysis-other@example.com")
    other_document = SourceDocument.create!(
      organization: other_user.organization,
      created_by: other_user,
      document_type: "xlsx_finance",
      filename: "Чужие финансы.xlsx",
      status: "parsed",
      parsed_payload: {}
    )

    post analysis_sessions_path, params: {
      program_version_id: @version.id,
      selected_source_document_ids: [other_document.id]
    }

    assert_response :not_found
  end

  private

  def login_as(user)
    post session_path, params: { email: user.email, password: "password123" }
  end
end
