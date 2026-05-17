class AlignSourceDocumentForeignKeyDeleteActions < ActiveRecord::Migration[8.0]
  CASCADE_REFERENCES = {
    excel_rows: :source_document_id,
    match_candidates: :source_document_id,
    reconciliations: :source_document_id,
    knowledge_chunks: :source_document_id,
    municipal_document_profiles: :source_document_id
  }.freeze

  NULLIFY_REFERENCES = {
    funding_lines: :source_document_id,
    change_sets: :source_document_id
  }.freeze

  def up
    CASCADE_REFERENCES.each do |table, column|
      replace_source_document_foreign_key(table, column, on_delete: :cascade)
    end

    NULLIFY_REFERENCES.each do |table, column|
      replace_source_document_foreign_key(table, column, on_delete: :nullify)
    end
  end

  def down
    CASCADE_REFERENCES.merge(NULLIFY_REFERENCES).each do |table, column|
      remove_foreign_key table, column: column, if_exists: true
      add_foreign_key table, :source_documents, column: column
    end
  end

  private

  def replace_source_document_foreign_key(table, column, on_delete:)
    remove_foreign_key table, column: column, if_exists: true
    add_foreign_key table, :source_documents, column: column, on_delete: on_delete
  end
end
