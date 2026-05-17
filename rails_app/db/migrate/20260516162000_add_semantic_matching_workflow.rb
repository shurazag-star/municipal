class AddSemanticMatchingWorkflow < ActiveRecord::Migration[8.0]
  def change
    add_column :analysis_sessions, :source_mode, :string, null: false, default: "auto"
    add_column :analysis_sessions, :source_policy, :jsonb, null: false, default: {}
    add_index :analysis_sessions, :source_mode

    create_table :agent_match_decisions do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: true, foreign_key: true
      t.references :analysis_session, null: true, foreign_key: true
      t.references :source_document, null: true, foreign_key: true
      t.references :match_candidate, null: true, foreign_key: true
      t.references :change_item, null: true, foreign_key: true
      t.references :selected_program_node, null: true, foreign_key: { to_table: :program_nodes }
      t.string :decision_type, null: false
      t.string :status, null: false, default: "created"
      t.decimal :confidence, precision: 5, scale: 4
      t.text :reason
      t.jsonb :input_snapshot, null: false, default: {}
      t.jsonb :candidate_snapshot, null: false, default: []
      t.jsonb :llm_output, null: false, default: {}
      t.jsonb :validation_result, null: false, default: {}
      t.string :model
      t.string :prompt_hash

      t.timestamps
    end

    add_index :agent_match_decisions, [:analysis_session_id, :status]
    add_index :agent_match_decisions, [:decision_type, :status]
    add_index :agent_match_decisions, :prompt_hash
  end
end
