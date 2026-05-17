# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_05_17_140500) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "agent_conversations", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "user_id", null: false
    t.string "title", default: "Рабочий чат"
    t.string "status", default: "active", null: false
    t.jsonb "context_snapshot", default: {}, null: false
    t.datetime "cleared_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "memory_summary"
    t.jsonb "working_state", default: {}, null: false
    t.datetime "memory_updated_at"
    t.index ["organization_id"], name: "index_agent_conversations_on_organization_id"
    t.index ["user_id"], name: "index_agent_conversations_on_user_id"
  end

  create_table "agent_match_decisions", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "user_id"
    t.bigint "analysis_session_id"
    t.bigint "source_document_id"
    t.bigint "match_candidate_id"
    t.bigint "change_item_id"
    t.bigint "selected_program_node_id"
    t.string "decision_type", null: false
    t.string "status", default: "created", null: false
    t.decimal "confidence", precision: 5, scale: 4
    t.text "reason"
    t.jsonb "input_snapshot", default: {}, null: false
    t.jsonb "candidate_snapshot", default: [], null: false
    t.jsonb "llm_output", default: {}, null: false
    t.jsonb "validation_result", default: {}, null: false
    t.string "model"
    t.string "prompt_hash"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["analysis_session_id", "status"], name: "index_agent_match_decisions_on_analysis_session_id_and_status"
    t.index ["analysis_session_id"], name: "index_agent_match_decisions_on_analysis_session_id"
    t.index ["change_item_id"], name: "index_agent_match_decisions_on_change_item_id"
    t.index ["decision_type", "status"], name: "index_agent_match_decisions_on_decision_type_and_status"
    t.index ["match_candidate_id"], name: "index_agent_match_decisions_on_match_candidate_id"
    t.index ["organization_id"], name: "index_agent_match_decisions_on_organization_id"
    t.index ["prompt_hash"], name: "index_agent_match_decisions_on_prompt_hash"
    t.index ["selected_program_node_id"], name: "index_agent_match_decisions_on_selected_program_node_id"
    t.index ["source_document_id"], name: "index_agent_match_decisions_on_source_document_id"
    t.index ["user_id"], name: "index_agent_match_decisions_on_user_id"
  end

  create_table "agent_messages", force: :cascade do |t|
    t.bigint "agent_conversation_id", null: false
    t.bigint "user_id"
    t.string "role", null: false
    t.text "content", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_conversation_id"], name: "index_agent_messages_on_agent_conversation_id"
    t.index ["user_id"], name: "index_agent_messages_on_user_id"
  end

  create_table "agent_settings", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.text "system_prompt", null: false
    t.string "primary_model"
    t.string "fast_model"
    t.decimal "temperature", precision: 3, scale: 2, default: "0.1", null: false
    t.decimal "match_confidence_threshold", precision: 5, scale: 4, default: "0.92", null: false
    t.decimal "money_tolerance_rub", precision: 20, scale: 2, default: "10.0", null: false
    t.boolean "use_knowledge_base", default: true, null: false
    t.boolean "use_chat_history", default: true, null: false
    t.boolean "auto_apply_exact_matches", default: false, null: false
    t.boolean "show_technical_statuses", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_agent_settings_on_organization_id", unique: true
  end

  create_table "agent_tasks", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "user_id", null: false
    t.bigint "agent_conversation_id", null: false
    t.bigint "agent_message_id"
    t.bigint "assistant_message_id"
    t.string "status", default: "queued", null: false
    t.string "task_type", null: false
    t.text "input_message"
    t.jsonb "progress_payload", default: {}, null: false
    t.jsonb "result_payload", default: {}, null: false
    t.text "error_message"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_conversation_id", "created_at"], name: "index_agent_tasks_on_agent_conversation_id_and_created_at"
    t.index ["agent_conversation_id"], name: "index_agent_tasks_on_agent_conversation_id"
    t.index ["agent_message_id"], name: "index_agent_tasks_on_agent_message_id"
    t.index ["assistant_message_id"], name: "index_agent_tasks_on_assistant_message_id"
    t.index ["organization_id", "status"], name: "index_agent_tasks_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_agent_tasks_on_organization_id"
    t.index ["user_id"], name: "index_agent_tasks_on_user_id"
  end

  create_table "agent_tool_calls", force: :cascade do |t|
    t.bigint "agent_conversation_id", null: false
    t.bigint "agent_message_id"
    t.string "tool_name", null: false
    t.jsonb "arguments", default: {}, null: false
    t.jsonb "result", default: {}, null: false
    t.string "status", default: "created", null: false
    t.text "error_message"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_conversation_id"], name: "index_agent_tool_calls_on_agent_conversation_id"
    t.index ["agent_message_id"], name: "index_agent_tool_calls_on_agent_message_id"
  end

  create_table "analysis_sessions", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "user_id", null: false
    t.bigint "program_version_id", null: false
    t.string "status", default: "draft", null: false
    t.text "goal"
    t.jsonb "selected_source_document_ids", default: [], null: false
    t.jsonb "summary", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source_mode", default: "auto", null: false
    t.jsonb "source_policy", default: {}, null: false
    t.index ["organization_id", "updated_at"], name: "index_analysis_sessions_on_organization_id_and_updated_at"
    t.index ["organization_id"], name: "index_analysis_sessions_on_organization_id"
    t.index ["program_version_id"], name: "index_analysis_sessions_on_program_version_id"
    t.index ["source_mode"], name: "index_analysis_sessions_on_source_mode"
    t.index ["user_id"], name: "index_analysis_sessions_on_user_id"
  end

  create_table "audit_logs", force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "organization_id"
    t.string "action", null: false
    t.string "auditable_type"
    t.bigint "auditable_id"
    t.jsonb "payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["auditable_type", "auditable_id"], name: "index_audit_logs_on_auditable_type_and_auditable_id"
    t.index ["organization_id"], name: "index_audit_logs_on_organization_id"
    t.index ["user_id"], name: "index_audit_logs_on_user_id"
  end

  create_table "change_items", force: :cascade do |t|
    t.bigint "change_set_id", null: false
    t.bigint "program_node_id"
    t.string "change_type", default: "amount_update", null: false
    t.string "field_name"
    t.integer "year"
    t.string "source_type"
    t.text "old_value"
    t.text "new_value"
    t.decimal "old_amount_rub", precision: 20, scale: 2
    t.decimal "new_amount_rub", precision: 20, scale: 2
    t.decimal "delta_rub", precision: 20, scale: 2
    t.jsonb "source_reference", default: {}, null: false
    t.decimal "confidence", precision: 5, scale: 4
    t.boolean "requires_user_confirmation", default: false, null: false
    t.boolean "user_confirmed", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "explanation"
    t.string "status", default: "draft", null: false
    t.string "agent_resolution_status", default: "unresolved", null: false
    t.text "agent_resolution_reason"
    t.jsonb "agent_resolution_evidence", default: {}, null: false
    t.string "agent_resolver_model"
    t.datetime "agent_resolved_at"
    t.index ["agent_resolution_status"], name: "index_change_items_on_agent_resolution_status"
    t.index ["change_set_id"], name: "index_change_items_on_change_set_id"
    t.index ["program_node_id"], name: "index_change_items_on_program_node_id"
  end

  create_table "change_sets", force: :cascade do |t|
    t.bigint "program_version_id", null: false
    t.bigint "source_document_id"
    t.string "status", default: "draft", null: false
    t.text "summary"
    t.bigint "created_by_id", null: false
    t.bigint "approved_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "analysis_session_id"
    t.bigint "target_program_version_id"
    t.datetime "applied_at"
    t.jsonb "export_summary", default: {}, null: false
    t.index ["analysis_session_id"], name: "index_change_sets_on_analysis_session_id"
    t.index ["approved_by_id"], name: "index_change_sets_on_approved_by_id"
    t.index ["created_by_id"], name: "index_change_sets_on_created_by_id"
    t.index ["program_version_id"], name: "index_change_sets_on_program_version_id"
    t.index ["source_document_id"], name: "index_change_sets_on_source_document_id"
    t.index ["target_program_version_id"], name: "index_change_sets_on_target_program_version_id"
  end

  create_table "excel_rows", force: :cascade do |t|
    t.bigint "source_document_id", null: false
    t.string "sheet_name", null: false
    t.integer "row_number", null: false
    t.string "row_type", null: false
    t.jsonb "raw_values", default: {}, null: false
    t.jsonb "normalized_values", default: {}, null: false
    t.jsonb "parent_context", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["source_document_id"], name: "index_excel_rows_on_source_document_id"
  end

  create_table "funding_lines", force: :cascade do |t|
    t.bigint "program_node_id", null: false
    t.integer "year", null: false
    t.string "source_type", null: false
    t.decimal "amount_rub", precision: 20, scale: 2, default: "0.0", null: false
    t.string "amount_kind", default: "planned", null: false
    t.bigint "source_document_id"
    t.string "source_row_ref"
    t.string "raw_source_name"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["program_node_id"], name: "index_funding_lines_on_program_node_id"
    t.index ["source_document_id"], name: "index_funding_lines_on_source_document_id"
  end

  create_table "funding_source_aliases", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "canonical_key", null: false
    t.string "label", null: false
    t.jsonb "aliases", default: [], null: false
    t.integer "sort_order", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "canonical_key"], name: "idx_on_organization_id_canonical_key_313696137d", unique: true
    t.index ["organization_id"], name: "index_funding_source_aliases_on_organization_id"
  end

  create_table "knowledge_chunks", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "source_document_id"
    t.string "chunk_type", default: "text", null: false
    t.text "title"
    t.text "content", null: false
    t.integer "page_number"
    t.integer "table_index"
    t.integer "row_index"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "chunk_type"], name: "index_knowledge_chunks_on_organization_id_and_chunk_type"
    t.index ["organization_id"], name: "index_knowledge_chunks_on_organization_id"
    t.index ["page_number"], name: "index_knowledge_chunks_on_page_number"
    t.index ["source_document_id"], name: "index_knowledge_chunks_on_source_document_id"
  end

  create_table "llm_runs", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "user_id"
    t.string "model", null: false
    t.string "purpose", null: false
    t.string "prompt_hash"
    t.jsonb "input_summary", default: {}, null: false
    t.jsonb "output", default: {}, null: false
    t.integer "tokens_input"
    t.integer "tokens_output"
    t.decimal "cost_usd", precision: 12, scale: 6
    t.string "status", default: "created", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_llm_runs_on_organization_id"
    t.index ["user_id"], name: "index_llm_runs_on_user_id"
  end

  create_table "manual_change_instructions", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "user_id"
    t.bigint "agent_conversation_id"
    t.bigint "change_set_id"
    t.bigint "program_node_id"
    t.string "source_mode", default: "manual_instruction", null: false
    t.string "operation", null: false
    t.text "object_ref"
    t.text "subprogram_ref"
    t.text "main_activity_ref"
    t.text "activity_ref"
    t.string "budget_source"
    t.integer "year"
    t.integer "from_year"
    t.integer "to_year"
    t.decimal "amount_rub", precision: 20, scale: 2
    t.text "text_evidence"
    t.string "clarification_status", default: "needs_clarification", null: false
    t.decimal "confidence", precision: 5, scale: 4, default: "0.0", null: false
    t.jsonb "structured_payload", default: {}, null: false
    t.jsonb "operations_payload", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_conversation_id"], name: "index_manual_change_instructions_on_agent_conversation_id"
    t.index ["change_set_id"], name: "index_manual_change_instructions_on_change_set_id"
    t.index ["organization_id", "clarification_status"], name: "idx_manual_instructions_org_status"
    t.index ["organization_id", "source_mode"], name: "idx_manual_instructions_org_source_mode"
    t.index ["organization_id"], name: "index_manual_change_instructions_on_organization_id"
    t.index ["program_node_id"], name: "index_manual_change_instructions_on_program_node_id"
    t.index ["user_id"], name: "index_manual_change_instructions_on_user_id"
  end

  create_table "match_candidates", force: :cascade do |t|
    t.bigint "program_version_id", null: false
    t.bigint "source_document_id", null: false
    t.bigint "program_node_id"
    t.bigint "excel_row_id"
    t.string "match_status", null: false
    t.decimal "confidence", precision: 5, scale: 4
    t.text "reason"
    t.boolean "requires_user_confirmation", default: false, null: false
    t.string "user_decision"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["excel_row_id"], name: "index_match_candidates_on_excel_row_id"
    t.index ["program_node_id"], name: "index_match_candidates_on_program_node_id"
    t.index ["program_version_id"], name: "index_match_candidates_on_program_version_id"
    t.index ["source_document_id"], name: "index_match_candidates_on_source_document_id"
  end

  create_table "municipal_document_profiles", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "municipal_program_id"
    t.bigint "source_document_id"
    t.string "status", default: "draft", null: false
    t.string "profile_type", null: false
    t.jsonb "schema_json", default: {}, null: false
    t.decimal "confidence", precision: 5, scale: 4, default: "0.0", null: false
    t.jsonb "warnings", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["municipal_program_id"], name: "index_municipal_document_profiles_on_municipal_program_id"
    t.index ["organization_id", "profile_type", "status"], name: "idx_on_organization_id_profile_type_status_b334b3d348"
    t.index ["organization_id"], name: "index_municipal_document_profiles_on_organization_id"
    t.index ["source_document_id"], name: "index_municipal_document_profiles_on_source_document_id"
  end

  create_table "municipal_programs", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "name", null: false
    t.integer "period_start_year"
    t.integer "period_end_year"
    t.bigint "current_version_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_municipal_programs_on_organization_id"
  end

  create_table "organizations", force: :cascade do |t|
    t.string "name", null: false
    t.string "municipality_name"
    t.string "region_name"
    t.jsonb "settings", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "procedure_documents", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "filename", null: false
    t.text "parsed_text"
    t.jsonb "parsed_rules", default: {}, null: false
    t.string "status", default: "uploaded", null: false
    t.bigint "created_by_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_procedure_documents_on_created_by_id"
    t.index ["organization_id"], name: "index_procedure_documents_on_organization_id"
  end

  create_table "program_nodes", force: :cascade do |t|
    t.bigint "program_version_id", null: false
    t.bigint "parent_id"
    t.string "node_type", null: false
    t.string "code"
    t.string "external_code"
    t.string "display_number"
    t.text "name", null: false
    t.text "normalized_name"
    t.string "responsible"
    t.string "execution_period"
    t.integer "source_table_index"
    t.integer "source_row_index"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_id"], name: "index_program_nodes_on_parent_id"
    t.index ["program_version_id"], name: "index_program_nodes_on_program_version_id"
  end

  create_table "program_versions", force: :cascade do |t|
    t.bigint "municipal_program_id", null: false
    t.integer "version_number", default: 1, null: false
    t.string "status", default: "imported", null: false
    t.jsonb "import_summary", default: {}, null: false
    t.bigint "created_by_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_program_versions_on_created_by_id"
    t.index ["municipal_program_id"], name: "index_program_versions_on_municipal_program_id"
  end

  create_table "reconciliations", force: :cascade do |t|
    t.bigint "program_version_id", null: false
    t.bigint "source_document_id", null: false
    t.bigint "program_node_id"
    t.string "status", null: false
    t.integer "year"
    t.string "source_type"
    t.decimal "word_amount_rub", precision: 20, scale: 2
    t.decimal "external_amount_rub", precision: 20, scale: 2
    t.decimal "delta_rub", precision: 20, scale: 2
    t.jsonb "details", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["program_node_id"], name: "index_reconciliations_on_program_node_id"
    t.index ["program_version_id"], name: "index_reconciliations_on_program_version_id"
    t.index ["source_document_id"], name: "index_reconciliations_on_source_document_id"
  end

  create_table "source_documents", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "document_type", default: "other", null: false
    t.string "filename", null: false
    t.string "status", default: "uploaded", null: false
    t.jsonb "parsed_payload", default: {}, null: false
    t.bigint "created_by_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_source_documents_on_created_by_id"
    t.index ["organization_id"], name: "index_source_documents_on_organization_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "role", default: "user", null: false
    t.bigint "organization_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["organization_id"], name: "index_users_on_organization_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_conversations", "organizations"
  add_foreign_key "agent_conversations", "users"
  add_foreign_key "agent_match_decisions", "analysis_sessions", on_delete: :nullify
  add_foreign_key "agent_match_decisions", "change_items", on_delete: :nullify
  add_foreign_key "agent_match_decisions", "match_candidates", on_delete: :nullify
  add_foreign_key "agent_match_decisions", "organizations"
  add_foreign_key "agent_match_decisions", "program_nodes", column: "selected_program_node_id", on_delete: :nullify
  add_foreign_key "agent_match_decisions", "source_documents", on_delete: :nullify
  add_foreign_key "agent_match_decisions", "users"
  add_foreign_key "agent_messages", "agent_conversations"
  add_foreign_key "agent_messages", "users"
  add_foreign_key "agent_settings", "organizations"
  add_foreign_key "agent_tasks", "agent_conversations"
  add_foreign_key "agent_tasks", "agent_messages"
  add_foreign_key "agent_tasks", "agent_messages", column: "assistant_message_id"
  add_foreign_key "agent_tasks", "organizations"
  add_foreign_key "agent_tasks", "users"
  add_foreign_key "agent_tool_calls", "agent_conversations"
  add_foreign_key "agent_tool_calls", "agent_messages"
  add_foreign_key "analysis_sessions", "organizations"
  add_foreign_key "analysis_sessions", "program_versions"
  add_foreign_key "analysis_sessions", "users"
  add_foreign_key "audit_logs", "organizations"
  add_foreign_key "audit_logs", "users"
  add_foreign_key "change_items", "change_sets"
  add_foreign_key "change_items", "program_nodes"
  add_foreign_key "change_sets", "analysis_sessions"
  add_foreign_key "change_sets", "program_versions"
  add_foreign_key "change_sets", "program_versions", column: "target_program_version_id"
  add_foreign_key "change_sets", "source_documents", on_delete: :nullify
  add_foreign_key "change_sets", "users", column: "approved_by_id"
  add_foreign_key "change_sets", "users", column: "created_by_id"
  add_foreign_key "excel_rows", "source_documents", on_delete: :cascade
  add_foreign_key "funding_lines", "program_nodes"
  add_foreign_key "funding_lines", "source_documents", on_delete: :nullify
  add_foreign_key "funding_source_aliases", "organizations"
  add_foreign_key "knowledge_chunks", "organizations"
  add_foreign_key "knowledge_chunks", "source_documents", on_delete: :cascade
  add_foreign_key "llm_runs", "organizations"
  add_foreign_key "llm_runs", "users"
  add_foreign_key "manual_change_instructions", "agent_conversations", on_delete: :nullify
  add_foreign_key "manual_change_instructions", "change_sets", on_delete: :nullify
  add_foreign_key "manual_change_instructions", "organizations"
  add_foreign_key "manual_change_instructions", "program_nodes", on_delete: :nullify
  add_foreign_key "manual_change_instructions", "users", on_delete: :nullify
  add_foreign_key "match_candidates", "excel_rows"
  add_foreign_key "match_candidates", "program_nodes"
  add_foreign_key "match_candidates", "program_versions"
  add_foreign_key "match_candidates", "source_documents", on_delete: :cascade
  add_foreign_key "municipal_document_profiles", "municipal_programs"
  add_foreign_key "municipal_document_profiles", "organizations"
  add_foreign_key "municipal_document_profiles", "source_documents", on_delete: :cascade
  add_foreign_key "municipal_programs", "organizations"
  add_foreign_key "municipal_programs", "program_versions", column: "current_version_id"
  add_foreign_key "procedure_documents", "organizations"
  add_foreign_key "procedure_documents", "users", column: "created_by_id"
  add_foreign_key "program_nodes", "program_nodes", column: "parent_id"
  add_foreign_key "program_nodes", "program_versions"
  add_foreign_key "program_versions", "municipal_programs"
  add_foreign_key "program_versions", "users", column: "created_by_id"
  add_foreign_key "reconciliations", "program_nodes"
  add_foreign_key "reconciliations", "program_versions"
  add_foreign_key "reconciliations", "source_documents", on_delete: :cascade
  add_foreign_key "source_documents", "organizations"
  add_foreign_key "source_documents", "users", column: "created_by_id"
  add_foreign_key "users", "organizations"
end
