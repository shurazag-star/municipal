class CreateAgentChatSchema < ActiveRecord::Migration[8.0]
  def change
    create_table :agent_settings do |t|
      t.references :organization, null: false, foreign_key: true, index: { unique: true }
      t.text :system_prompt, null: false
      t.string :primary_model
      t.string :fast_model
      t.decimal :temperature, precision: 3, scale: 2, null: false, default: 0.1
      t.decimal :match_confidence_threshold, precision: 5, scale: 4, null: false, default: 0.92
      t.decimal :money_tolerance_rub, precision: 20, scale: 2, null: false, default: 10
      t.boolean :use_knowledge_base, null: false, default: true
      t.boolean :use_chat_history, null: false, default: true
      t.boolean :auto_apply_exact_matches, null: false, default: false
      t.boolean :show_technical_statuses, null: false, default: false
      t.timestamps
    end
    create_table :agent_conversations do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :title, default: "Рабочий чат"
      t.string :status, null: false, default: "active"
      t.jsonb :context_snapshot, null: false, default: {}
      t.datetime :cleared_at
      t.timestamps
    end

    create_table :agent_messages do |t|
      t.references :agent_conversation, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :role, null: false
      t.text :content, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    create_table :agent_tool_calls do |t|
      t.references :agent_conversation, null: false, foreign_key: true
      t.references :agent_message, foreign_key: true
      t.string :tool_name, null: false
      t.jsonb :arguments, null: false, default: {}
      t.jsonb :result, null: false, default: {}
      t.string :status, null: false, default: "created"
      t.text :error_message
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
  end
end
