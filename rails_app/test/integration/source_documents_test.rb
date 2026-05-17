require "test_helper"

class SourceDocumentsTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_isolated_user!(email: "documents-delete@example.com")
    @organization = @user.organization
    @document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "xlsx_finance",
      filename: "Финансы.xlsx",
      status: "parsed",
      parsed_payload: {}
    )
    post session_path, params: { email: @user.email, password: "password123" }
  end

  test "documents page shows delete buttons with confirmation" do
    get source_documents_path

    assert_response :success
    assert_select "h2", "Порядок разработки / нормативная база — не источник сумм"
    assert_select "h2", "Документы-основания для изменений — Excel финансистов или PDF-соглашения"
    assert_select ".source-mode-selector", /Excel как целевая модель/
    assert_select "form[action='#{set_source_mode_source_documents_path}'] button", "PDF как основание изменений"
    assert_select "form[action='#{set_source_mode_source_documents_path}'] button", "Ручной ввод в чате"
    assert_select "form[action='#{clear_change_sources_source_documents_path}'] button", "Очистить документы-основания"
    assert_select "form[action='#{clear_change_projects_source_documents_path}'] button", "Очистить проекты изменений"
    assert_select "form[action='#{clear_program_versions_source_documents_path}'] button", "Очистить версии программы"
    assert_select "form[action='#{clear_workspace_source_documents_path}'] button", "Очистить все рабочие данные"
    assert_select "form[action='#{source_document_path(@document)}'][method='post']" do
      assert_select "input[name='_method'][value='delete']", count: 1
      assert_select "button[title='Удалить файл']", text: "×"
      assert_select "[data-turbo-confirm='Вы уверены, что хотите удалить файл «Финансы.xlsx»?']"
    end
    assert_select "script", /setupConfirmableForms/
  end

  test "upload rejects files over configured size limit" do
    previous_max_upload_bytes = ENV["MAX_UPLOAD_BYTES"]
    ENV["MAX_UPLOAD_BYTES"] = "4"
    file_path = Rails.root.join("tmp", "too_large.pdf")
    File.binwrite(file_path, "%PDF-1.4\n")
    upload = Rack::Test::UploadedFile.new(file_path, "application/pdf")

    assert_no_difference "SourceDocument.count" do
      assert_no_enqueued_jobs only: ParseDocumentJob do
        post source_documents_path, params: { document_type: "pdf_agreement", file: upload }
      end
    end

    assert_redirected_to source_documents_path
    follow_redirect!
    assert_select ".alert", /Файл слишком большой/
  ensure
    ENV["MAX_UPLOAD_BYTES"] = previous_max_upload_bytes
    File.delete(file_path) if file_path && File.exist?(file_path)
  end

  test "user can select source mode for change documents" do
    post set_source_mode_source_documents_path, params: { source_mode: "pdf_patch" }

    assert_redirected_to source_documents_path
    assert_equal "pdf_patch", @organization.reload.settings["default_source_mode"]
  end

  test "user can make parsed program document active" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed",
      parsed_payload: {
        "program" => {
          "name" => "Активная программа",
          "period_start_year" => 2026,
          "period_end_year" => 2030
        },
        "nodes" => [
          {
            "stable_key" => "program",
            "node_type" => "program",
            "name" => "Активная программа",
            "normalized_name" => "активная программа",
            "metadata" => {}
          }
        ],
        "funding_lines" => []
      }
    )

    assert_difference "ProgramVersion.count", 1 do
      post make_active_source_document_path(document)
    end

    assert_redirected_to source_documents_path
    version = @organization.program_versions.where("import_summary ->> 'source_document_id' = ?", document.id.to_s).sole
    assert_equal version, version.municipal_program.current_version
  end

  test "user can delete own uploaded document" do
    assert_difference "SourceDocument.count", -1 do
      delete source_document_path(@document)
    end

    assert_redirected_to source_documents_path
    follow_redirect!
    assert_select ".notice", /Файл удален/
  end

  test "user can delete parsed finance document with excel rows and match candidates" do
    program = MunicipalProgram.create!(organization: @organization, name: "Тестовая программа", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    excel_row = @document.excel_rows.create!(
      sheet_name: "Результат",
      row_number: 25,
      row_type: "OBJECT_LEAF_ROW"
    )
    MatchCandidate.create!(
      program_version: version,
      source_document: @document,
      excel_row: excel_row,
      match_status: "MATCH_EXACT_NAME",
      confidence: "1.0",
      reason: "Тестовая связь"
    )

    assert_difference "SourceDocument.count", -1 do
      assert_difference "ExcelRow.count", -1 do
        assert_difference "MatchCandidate.count", -1 do
          delete source_document_path(@document)
        end
      end
    end

    assert_redirected_to source_documents_path
  end

  test "user can delete source document referenced by semantic agent decisions" do
    decision = AgentMatchDecision.create!(
      organization: @organization,
      user: @user,
      source_document: @document,
      decision_type: "existing_object",
      status: "accepted",
      confidence: "0.9500",
      reason: "Тестовая связь аудита"
    )

    assert_difference "SourceDocument.count", -1 do
      assert_no_difference "AgentMatchDecision.count" do
        delete source_document_path(@document)
      end
    end

    assert_redirected_to source_documents_path
    assert_nil decision.reload.source_document_id
  end

  test "user can delete procedure document with knowledge chunks and document profile" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed",
      parsed_payload: {}
    )
    KnowledgeChunk.create!(
      organization: @organization,
      source_document: document,
      chunk_type: "procedure_general",
      title: "Порядок",
      content: "Правило"
    )
    MunicipalDocumentProfile.create!(
      organization: @organization,
      source_document: document,
      profile_type: "procedure",
      status: "active",
      confidence: "0.95"
    )

    assert_difference "SourceDocument.count", -1 do
      assert_difference "KnowledgeChunk.count", -1 do
        assert_difference "MunicipalDocumentProfile.count", -1 do
          delete source_document_path(document)
        end
      end
    end

    assert_redirected_to source_documents_path
  end

  test "user can delete program document referenced by funding lines and change sets" do
    document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "docx_program",
      filename: "Программа.docx",
      status: "parsed",
      parsed_payload: {}
    )
    program = MunicipalProgram.create!(organization: @organization, name: "Тестовая программа", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    node = version.program_nodes.create!(node_type: "object", name: "Объект", normalized_name: "объект")
    funding_line = node.funding_lines.create!(
      year: 2026,
      source_type: "LOCAL_BUDGET",
      amount_rub: "100.00",
      source_document: document
    )
    change_set = ChangeSet.create!(
      program_version: version,
      source_document: document,
      status: "pending_confirmation",
      summary: "Проект",
      created_by: @user
    )

    assert_difference "SourceDocument.count", -1 do
      assert_no_difference "FundingLine.count" do
        assert_no_difference "ChangeSet.count" do
          delete source_document_path(document)
        end
      end
    end

    assert_redirected_to source_documents_path
    assert_nil funding_line.reload.source_document_id
    assert_nil change_set.reload.source_document_id
  end

  test "source document foreign keys have database delete actions aligned with model ownership" do
    expected_actions = {
      "excel_rows" => "cascade",
      "match_candidates" => "cascade",
      "reconciliations" => "cascade",
      "knowledge_chunks" => "cascade",
      "municipal_document_profiles" => "cascade",
      "funding_lines" => "nullify",
      "change_sets" => "nullify",
      "agent_match_decisions" => "nullify"
    }

    expected_actions.each do |table, expected_action|
      foreign_key = ActiveRecord::Base.connection.foreign_keys(table).find do |key|
        key.to_table == "source_documents" && key.column == "source_document_id"
      end

      assert foreign_key, "Expected #{table}.source_document_id to reference source_documents"
      assert_equal expected_action, foreign_key.on_delete.to_s
    end
  end

  test "user cannot delete another organization document" do
    other_user = create_isolated_user!(email: "documents-delete-other@example.com")
    other_document = SourceDocument.create!(
      organization: other_user.organization,
      created_by: other_user,
      document_type: "docx_program",
      filename: "Чужая программа.docx",
      status: "parsed",
      parsed_payload: {}
    )

    assert_no_difference "SourceDocument.count" do
      delete source_document_path(other_document)
    end

    assert_response :not_found
  end

  test "clear change sources deletes change documents and dependent projects but keeps procedure program and settings" do
    procedure = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "pdf_procedure", filename: "Порядок.pdf", status: "parsed")
    program_doc = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "docx_program", filename: "Программа.docx", status: "parsed")
    xlsx = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "xlsx_finance", filename: "Финансы.xlsx", status: "parsed")
    pdf = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "pdf_agreement", filename: "Соглашение.pdf", status: "parsed")
    program = MunicipalProgram.create!(organization: @organization, name: "Тестовая программа", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    session = AnalysisSession.create!(organization: @organization, user: @user, program_version: version, selected_source_document_ids: [xlsx.id, pdf.id])
    ChangeSet.create!(program_version: version, status: "draft", summary: "Проект", created_by: @user)
    decision = AgentMatchDecision.create!(
      organization: @organization,
      user: @user,
      analysis_session: session,
      source_document: xlsx,
      decision_type: "existing_object",
      status: "accepted",
      confidence: "0.9500",
      reason: "Тестовая связь аудита"
    )
    setting = AgentSetting.for_organization!(@organization)

    delete clear_change_sources_source_documents_path

    assert_redirected_to source_documents_path
    assert SourceDocument.exists?(procedure.id)
    assert SourceDocument.exists?(program_doc.id)
    assert_not SourceDocument.exists?(xlsx.id)
    assert_not SourceDocument.exists?(pdf.id)
    assert_equal 0, AnalysisSession.where(organization: @organization).count
    assert_equal 0, ChangeSet.joins(program_version: :municipal_program).where(municipal_programs: { organization_id: @organization.id }).count
    assert_nil decision.reload.analysis_session_id
    assert_nil decision.source_document_id
    assert AgentSetting.exists?(setting.id)
  end

  test "clear change projects removes analysis sessions and applied projects without touching documents or program" do
    program_doc = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "docx_program", filename: "Программа.docx", status: "parsed")
    xlsx = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "xlsx_finance", filename: "Финансы 2.xlsx", status: "parsed")
    program = MunicipalProgram.create!(organization: @organization, name: "Тестовая программа", period_start_year: 2026, period_end_year: 2030)
    source_version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    target_version = program.program_versions.create!(created_by: @user, version_number: 2, status: "changed")
    program.update!(current_version: target_version)
    session = AnalysisSession.create!(organization: @organization, user: @user, program_version: source_version, selected_source_document_ids: [xlsx.id])
    change_set = ChangeSet.create!(
      program_version: source_version,
      target_program_version: target_version,
      analysis_session: session,
      source_document: xlsx,
      status: "applied",
      summary: "Готовый проект",
      created_by: @user
    )
    change_set.change_items.create!(change_type: "amount_update", status: "confirmed", field_name: "amount_rub")

    delete clear_change_projects_source_documents_path

    assert_redirected_to source_documents_path
    assert SourceDocument.exists?(program_doc.id)
    assert SourceDocument.exists?(xlsx.id)
    assert MunicipalProgram.exists?(program.id)
    assert ProgramVersion.exists?(source_version.id)
    assert ProgramVersion.exists?(target_version.id)
    assert_not ChangeSet.exists?(change_set.id)
    assert_not AnalysisSession.exists?(session.id)
  end

  test "clear program versions removes program tree and match candidates without deleting source documents" do
    program_doc = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "docx_program", filename: "Программа.docx", status: "parsed")
    xlsx = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "xlsx_finance", filename: "Финансы 2.xlsx", status: "parsed")
    program = MunicipalProgram.create!(organization: @organization, name: "Тестовая программа", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    program.update!(current_version: version)
    node = version.program_nodes.create!(node_type: "object", name: "Объект", normalized_name: "объект")
    excel_row = xlsx.excel_rows.create!(sheet_name: "Результат", row_number: 10, row_type: "OBJECT_LEAF_ROW")
    candidate = MatchCandidate.create!(
      program_version: version,
      source_document: xlsx,
      program_node: node,
      excel_row: excel_row,
      match_status: "MATCH_EXACT_NAME",
      confidence: "1.0",
      reason: "Тестовая связь"
    )
    MunicipalDocumentProfile.create!(
      organization: @organization,
      municipal_program: program,
      source_document: program_doc,
      profile_type: "docx_program",
      status: "active",
      confidence: "0.95"
    )
    decision = AgentMatchDecision.create!(
      organization: @organization,
      user: @user,
      source_document: xlsx,
      match_candidate: candidate,
      selected_program_node: node,
      decision_type: "existing_object",
      status: "accepted",
      confidence: "0.9500",
      reason: "Тестовая связь аудита"
    )

    delete clear_program_versions_source_documents_path

    assert_redirected_to source_documents_path
    assert_not MunicipalProgram.exists?(program.id)
    assert_not ProgramVersion.exists?(version.id)
    assert_not ProgramNode.exists?(node.id)
    assert_not MatchCandidate.exists?(candidate.id)
    assert_nil decision.reload.match_candidate_id
    assert_nil decision.selected_program_node_id
    assert SourceDocument.exists?(program_doc.id)
    assert SourceDocument.exists?(xlsx.id)
  end

  test "clear workspace removes all workspace data with cross references but keeps settings" do
    procedure = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "pdf_procedure", filename: "Порядок.pdf", status: "parsed")
    program_doc = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "docx_program", filename: "Программа.docx", status: "parsed")
    xlsx = SourceDocument.create!(organization: @organization, created_by: @user, document_type: "xlsx_finance", filename: "Финансы 2.xlsx", status: "parsed")
    program = MunicipalProgram.create!(organization: @organization, name: "Тестовая программа", period_start_year: 2026, period_end_year: 2030)
    version = program.program_versions.create!(created_by: @user, version_number: 1, status: "imported")
    target_version = program.program_versions.create!(created_by: @user, version_number: 2, status: "changed")
    program.update!(current_version: target_version)
    node = version.program_nodes.create!(node_type: "object", name: "Объект", normalized_name: "объект")
    node.funding_lines.create!(year: 2026, source_type: "LOCAL_BUDGET", amount_rub: "100.00", source_document: program_doc)
    excel_row = xlsx.excel_rows.create!(sheet_name: "Результат", row_number: 10, row_type: "OBJECT_LEAF_ROW")
    MatchCandidate.create!(
      program_version: version,
      source_document: xlsx,
      program_node: node,
      excel_row: excel_row,
      match_status: "MATCH_EXACT_NAME",
      confidence: "1.0",
      reason: "Тестовая связь"
    )
    session = AnalysisSession.create!(organization: @organization, user: @user, program_version: version, selected_source_document_ids: [xlsx.id])
    ChangeSet.create!(program_version: version, target_program_version: target_version, analysis_session: session, status: "applied", summary: "Проект", created_by: @user)
    Reconciliation.create!(program_version: version, source_document: xlsx, program_node: node, status: "mismatch", year: 2026)
    KnowledgeChunk.create!(organization: @organization, source_document: procedure, title: "Порядок", content: "Текст")
    MunicipalDocumentProfile.create!(
      organization: @organization,
      municipal_program: program,
      source_document: program_doc,
      profile_type: "docx_program",
      status: "active",
      confidence: "0.95"
    )
    decision = AgentMatchDecision.create!(
      organization: @organization,
      user: @user,
      analysis_session: session,
      source_document: xlsx,
      selected_program_node: node,
      decision_type: "existing_object",
      status: "accepted",
      confidence: "0.9500",
      reason: "Тестовая связь аудита"
    )
    setting = AgentSetting.for_organization!(@organization)

    delete clear_workspace_source_documents_path

    assert_redirected_to source_documents_path
    assert_equal 0, SourceDocument.where(organization: @organization).count
    assert_equal 0, MunicipalProgram.where(organization: @organization).count
    assert_equal 0, AnalysisSession.where(organization: @organization).count
    assert_equal 0, ChangeSet.joins(program_version: :municipal_program).where(municipal_programs: { organization_id: @organization.id }).count
    assert_equal 0, KnowledgeChunk.where(organization: @organization).count
    assert_equal 0, MunicipalDocumentProfile.where(organization: @organization).count
    assert_nil decision.reload.analysis_session_id
    assert_nil decision.source_document_id
    assert_nil decision.selected_program_node_id
    assert AgentSetting.exists?(setting.id)
    assert User.exists?(@user.id)
    assert Organization.exists?(@organization.id)
  end
end
