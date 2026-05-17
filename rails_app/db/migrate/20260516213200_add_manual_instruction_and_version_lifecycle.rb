class AddManualInstructionAndVersionLifecycle < ActiveRecord::Migration[8.0]
  def change
    create_table :manual_change_instructions do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.references :agent_conversation, foreign_key: true
      t.references :change_set, foreign_key: true
      t.references :program_node, foreign_key: true
      t.string :source_mode, null: false, default: "manual_instruction"
      t.string :operation, null: false
      t.text :object_ref
      t.text :subprogram_ref
      t.text :main_activity_ref
      t.text :activity_ref
      t.string :budget_source
      t.integer :year
      t.integer :from_year
      t.integer :to_year
      t.decimal :amount_rub, precision: 20, scale: 2
      t.text :text_evidence
      t.string :clarification_status, null: false, default: "needs_clarification"
      t.decimal :confidence, precision: 5, scale: 4, default: "0.0", null: false
      t.jsonb :structured_payload, null: false, default: {}
      t.jsonb :operations_payload, null: false, default: []

      t.timestamps
    end

    add_index :manual_change_instructions, [:organization_id, :clarification_status], name: "idx_manual_instructions_org_status"
    add_index :manual_change_instructions, [:organization_id, :source_mode], name: "idx_manual_instructions_org_source_mode"
  end
end
