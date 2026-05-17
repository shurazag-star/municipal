require "test_helper"

class KnowledgeBaseTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_isolated_user!(email: "knowledge-base@example.com")
    @organization = @user.organization
    login_as(@user)
    @procedure = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    @organization.knowledge_chunks.create!(
      source_document: @procedure,
      chunk_type: "approval_terms",
      title: "Сроки согласования",
      content: "Согласование проекта выполняется в течение 5 рабочих дней.",
      page_number: 7
    )
  end

  test "shows indexed chunks for the active procedure" do
    get knowledge_chunks_path

    assert_response :success
    assert_select "h1", "База знаний"
    assert_select "body", /Порядок.pdf/
    assert_select "body", /Сроки согласования/
    assert_select "body", /5 рабочих дней/
  end

  test "searches chunks without leaking another organization" do
    other_user = create_isolated_user!(email: "other-knowledge@example.com")
    other_doc = SourceDocument.create!(
      organization: other_user.organization,
      created_by: other_user,
      document_type: "pdf_procedure",
      filename: "Чужой порядок.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    other_user.organization.knowledge_chunks.create!(
      source_document: other_doc,
      chunk_type: "reporting",
      title: "Чужой отчет",
      content: "Скрытый фрагмент другой организации"
    )

    get knowledge_chunks_path, params: { q: "согласование" }

    assert_response :success
    assert_select "body", /Сроки согласования/
    assert_select "body", { text: /Скрытый фрагмент/, count: 0 }
  end

  private

  def login_as(user)
    post session_path, params: { email: user.email, password: "password123" }
  end
end
