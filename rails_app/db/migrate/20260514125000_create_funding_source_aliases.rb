class CreateFundingSourceAliases < ActiveRecord::Migration[7.2]
  def change
    create_table :funding_source_aliases do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :canonical_key, null: false
      t.string :label, null: false
      t.jsonb :aliases, null: false, default: []
      t.integer :sort_order, null: false, default: 0

      t.timestamps
    end

    add_index :funding_source_aliases, [:organization_id, :canonical_key], unique: true
  end
end
