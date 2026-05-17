class NullifyManualInstructionOptionalForeignKeys < ActiveRecord::Migration[8.0]
  OPTIONAL_FOREIGN_KEYS = {
    user_id: :users,
    agent_conversation_id: :agent_conversations,
    change_set_id: :change_sets,
    program_node_id: :program_nodes
  }.freeze

  def change
    OPTIONAL_FOREIGN_KEYS.each do |column, table|
      remove_foreign_key :manual_change_instructions, column: column
      add_foreign_key :manual_change_instructions, table, column: column, on_delete: :nullify
    end
  end
end
