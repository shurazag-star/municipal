class CreateKnowledgeChunks < ActiveRecord::Migration[8.0]
  def change
    create_table :knowledge_chunks do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :source_document, foreign_key: true
      t.string :chunk_type, null: false, default: "text"
      t.text :title
      t.text :content, null: false
      t.integer :page_number
      t.integer :table_index
      t.integer :row_index
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :knowledge_chunks, %i[organization_id chunk_type]
    add_index :knowledge_chunks, :page_number
  end
end
