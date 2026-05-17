require "test_helper"

class UserFlowTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_user!
    MunicipalProgram.create!(
      organization: @user.organization,
      name: "Развитие жилищно-коммунального хозяйства",
      period_start_year: 2026,
      period_end_year: 2030
    )
  end

  test "dashboard requires login and login opens agent workspace" do
    get root_path

    assert_redirected_to new_session_path
    follow_redirect!
    assert_select "h1", "Вход"
    assert_select "input[name=email]"
    assert_select "input[name=password]"

    post session_path, params: { email: "admin@example.com", password: "password123" }
    assert_redirected_to root_path
    follow_redirect!

    assert_select "h1", "Муниципальный программный агент"
    assert_select "h2", "Чат с агентом"
    assert_select "h2", "Контекст агента"
    assert_select "a[href='#{agent_settings_path}']", "Настройка агента"
    assert_select "form[action='#{session_path}'] button", "Выйти"
  end

  test "upload without a file redirects with clear validation and no record" do
    post session_path, params: { email: "admin@example.com", password: "password123" }

    assert_no_difference "SourceDocument.count" do
      post uploads_path, params: { document_type: "docx_program" }
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".alert", /Выберите файл/
  end

  test "uploads url opens dashboard for a logged in user" do
    post session_path, params: { email: "admin@example.com", password: "password123" }

    get "/uploads"

    assert_response :success
    assert_select "h1", "Документы"
  end
end
