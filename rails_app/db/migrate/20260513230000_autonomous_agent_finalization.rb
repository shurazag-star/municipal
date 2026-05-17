class AutonomousAgentFinalization < ActiveRecord::Migration[8.0]
  def change
    add_column :agent_conversations, :memory_summary, :text
    add_column :agent_conversations, :working_state, :jsonb, null: false, default: {}
    add_column :agent_conversations, :memory_updated_at, :datetime

    add_column :change_items, :agent_resolution_status, :string, null: false, default: "unresolved"
    add_column :change_items, :agent_resolution_reason, :text
    add_column :change_items, :agent_resolution_evidence, :jsonb, null: false, default: {}
    add_column :change_items, :agent_resolver_model, :string
    add_column :change_items, :agent_resolved_at, :datetime
    add_index :change_items, :agent_resolution_status

    create_table :agent_tasks do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :agent_conversation, null: false, foreign_key: true
      t.references :agent_message, foreign_key: true
      t.references :assistant_message, foreign_key: { to_table: :agent_messages }
      t.string :status, null: false, default: "queued"
      t.string :task_type, null: false
      t.text :input_message
      t.jsonb :progress_payload, null: false, default: {}
      t.jsonb :result_payload, null: false, default: {}
      t.text :error_message
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :agent_tasks, [:organization_id, :status]
    add_index :agent_tasks, [:agent_conversation_id, :created_at]
  end
end
