class CreateMunicipalAgentSchema < ActiveRecord::Migration[8.0]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :municipality_name
      t.string :region_name
      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end

    create_table :users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :role, null: false, default: "user"
      t.references :organization, foreign_key: true
      t.timestamps
    end
    add_index :users, :email, unique: true

    create_table :procedure_documents do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :filename, null: false
      t.text :parsed_text
      t.jsonb :parsed_rules, null: false, default: {}
      t.string :status, null: false, default: "uploaded"
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end

    create_table :municipal_programs do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :period_start_year
      t.integer :period_end_year
      t.bigint :current_version_id
      t.timestamps
    end

    create_table :program_versions do |t|
      t.references :municipal_program, null: false, foreign_key: true
      t.integer :version_number, null: false, default: 1
      t.string :status, null: false, default: "imported"
      t.jsonb :import_summary, null: false, default: {}
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_foreign_key :municipal_programs, :program_versions, column: :current_version_id

    create_table :program_nodes do |t|
      t.references :program_version, null: false, foreign_key: true
      t.references :parent, foreign_key: { to_table: :program_nodes }
      t.string :node_type, null: false
      t.string :code
      t.string :external_code
      t.string :display_number
      t.text :name, null: false
      t.text :normalized_name
      t.string :responsible
      t.string :execution_period
      t.integer :source_table_index
      t.integer :source_row_index
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    create_table :source_documents do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :document_type, null: false, default: "other"
      t.string :filename, null: false
      t.string :status, null: false, default: "uploaded"
      t.jsonb :parsed_payload, null: false, default: {}
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end

    create_table :funding_lines do |t|
      t.references :program_node, null: false, foreign_key: true
      t.integer :year, null: false
      t.string :source_type, null: false
      t.decimal :amount_rub, precision: 20, scale: 2, null: false, default: 0
      t.string :amount_kind, null: false, default: "planned"
      t.references :source_document, foreign_key: true
      t.string :source_row_ref
      t.string :raw_source_name
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    create_table :excel_rows do |t|
      t.references :source_document, null: false, foreign_key: true
      t.string :sheet_name, null: false
      t.integer :row_number, null: false
      t.string :row_type, null: false
      t.jsonb :raw_values, null: false, default: {}
      t.jsonb :normalized_values, null: false, default: {}
      t.jsonb :parent_context, null: false, default: {}
      t.timestamps
    end

    create_table :match_candidates do |t|
      t.references :program_version, null: false, foreign_key: true
      t.references :source_document, null: false, foreign_key: true
      t.references :program_node, foreign_key: true
      t.references :excel_row, foreign_key: true
      t.string :match_status, null: false
      t.decimal :confidence, precision: 5, scale: 4
      t.text :reason
      t.boolean :requires_user_confirmation, null: false, default: false
      t.string :user_decision
      t.timestamps
    end

    create_table :reconciliations do |t|
      t.references :program_version, null: false, foreign_key: true
      t.references :source_document, null: false, foreign_key: true
      t.references :program_node, foreign_key: true
      t.string :status, null: false
      t.integer :year
      t.string :source_type
      t.decimal :word_amount_rub, precision: 20, scale: 2
      t.decimal :external_amount_rub, precision: 20, scale: 2
      t.decimal :delta_rub, precision: 20, scale: 2
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end

    create_table :change_sets do |t|
      t.references :program_version, null: false, foreign_key: true
      t.references :source_document, foreign_key: true
      t.string :status, null: false, default: "draft"
      t.text :summary
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    create_table :change_items do |t|
      t.references :change_set, null: false, foreign_key: true
      t.references :program_node, foreign_key: true
      t.string :change_type, null: false, default: "amount_update"
      t.string :field_name
      t.integer :year
      t.string :source_type
      t.text :old_value
      t.text :new_value
      t.decimal :old_amount_rub, precision: 20, scale: 2
      t.decimal :new_amount_rub, precision: 20, scale: 2
      t.decimal :delta_rub, precision: 20, scale: 2
      t.jsonb :source_reference, null: false, default: {}
      t.decimal :confidence, precision: 5, scale: 4
      t.boolean :requires_user_confirmation, null: false, default: false
      t.boolean :user_confirmed, null: false, default: false
      t.timestamps
    end

    create_table :audit_logs do |t|
      t.references :user, foreign_key: true
      t.references :organization, foreign_key: true
      t.string :action, null: false
      t.string :auditable_type
      t.bigint :auditable_id
      t.jsonb :payload, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :audit_logs, %i[auditable_type auditable_id]

    create_table :llm_runs do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :model, null: false
      t.string :purpose, null: false
      t.string :prompt_hash
      t.jsonb :input_summary, null: false, default: {}
      t.jsonb :output, null: false, default: {}
      t.integer :tokens_input
      t.integer :tokens_output
      t.decimal :cost_usd, precision: 12, scale: 6
      t.string :status, null: false, default: "created"
      t.timestamps
    end

    create_table :active_storage_blobs do |t|
      t.string :key, null: false
      t.string :filename, null: false
      t.string :content_type
      t.text :metadata
      t.string :service_name, null: false
      t.bigint :byte_size, null: false
      t.string :checksum
      t.datetime :created_at, null: false
      t.index :key, unique: true
    end

    create_table :active_storage_attachments do |t|
      t.string :name, null: false
      t.references :record, null: false, polymorphic: true, index: false
      t.references :blob, null: false
      t.datetime :created_at, null: false
      t.index %i[record_type record_id name blob_id], name: "index_active_storage_attachments_uniqueness", unique: true
      t.foreign_key :active_storage_blobs, column: :blob_id
    end

    create_table :active_storage_variant_records do |t|
      t.belongs_to :blob, null: false, index: false
      t.string :variation_digest, null: false
      t.index %i[blob_id variation_digest], name: "index_active_storage_variant_records_uniqueness", unique: true
      t.foreign_key :active_storage_blobs, column: :blob_id
    end
  end
end

