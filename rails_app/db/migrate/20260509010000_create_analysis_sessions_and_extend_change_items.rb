class CreateAnalysisSessionsAndExtendChangeItems < ActiveRecord::Migration[8.0]
  def change
    create_table :analysis_sessions do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :program_version, null: false, foreign_key: true
      t.string :status, default: "draft", null: false
      t.text :goal
      t.jsonb :selected_source_document_ids, default: [], null: false
      t.jsonb :summary, default: {}, null: false
      t.timestamps
    end

    add_index :analysis_sessions, %i[organization_id updated_at]
    add_reference :change_sets, :analysis_session, foreign_key: true
    add_column :change_items, :explanation, :text
    add_column :change_items, :status, :string, default: "draft", null: false
  end
end
