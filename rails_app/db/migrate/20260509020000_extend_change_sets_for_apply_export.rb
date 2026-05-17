class ExtendChangeSetsForApplyExport < ActiveRecord::Migration[8.0]
  def change
    add_reference :change_sets, :target_program_version, foreign_key: { to_table: :program_versions }
    add_column :change_sets, :applied_at, :datetime
    add_column :change_sets, :export_summary, :jsonb, null: false, default: {}
  end
end
