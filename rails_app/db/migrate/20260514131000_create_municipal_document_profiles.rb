class CreateMunicipalDocumentProfiles < ActiveRecord::Migration[7.2]
  def change
    create_table :municipal_document_profiles do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :municipal_program, null: true, foreign_key: true
      t.references :source_document, null: true, foreign_key: true
      t.string :status, null: false, default: "draft"
      t.string :profile_type, null: false
      t.jsonb :schema_json, null: false, default: {}
      t.decimal :confidence, precision: 5, scale: 4, null: false, default: "0.0"
      t.jsonb :warnings, null: false, default: []

      t.timestamps
    end

    add_index :municipal_document_profiles, [:organization_id, :profile_type, :status]
  end
end
