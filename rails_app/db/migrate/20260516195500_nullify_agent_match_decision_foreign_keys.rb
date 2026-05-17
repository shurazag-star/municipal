class NullifyAgentMatchDecisionForeignKeys < ActiveRecord::Migration[8.0]
  NULLIFY_REFERENCES = {
    analysis_session_id: :analysis_sessions,
    source_document_id: :source_documents,
    match_candidate_id: :match_candidates,
    change_item_id: :change_items,
    selected_program_node_id: :program_nodes
  }.freeze

  def up
    NULLIFY_REFERENCES.each do |column, table|
      remove_foreign_key :agent_match_decisions, column: column, if_exists: true
      add_foreign_key :agent_match_decisions, table, column: column, on_delete: :nullify
    end
  end

  def down
    NULLIFY_REFERENCES.each do |column, table|
      remove_foreign_key :agent_match_decisions, column: column, if_exists: true
      add_foreign_key :agent_match_decisions, table, column: column
    end
  end
end
