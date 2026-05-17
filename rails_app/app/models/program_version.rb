class ProgramVersion < ApplicationRecord
  belongs_to :municipal_program
  belongs_to :created_by, class_name: "User"

  has_many :program_nodes, dependent: :destroy
  has_many :reconciliations, dependent: :destroy
  has_many :match_candidates, dependent: :destroy
  has_many :change_sets, dependent: :destroy
  has_many :targeted_change_sets, class_name: "ChangeSet", foreign_key: :target_program_version_id, dependent: :nullify
  has_many :analysis_sessions, dependent: :destroy
  has_many :current_municipal_programs, class_name: "MunicipalProgram", foreign_key: :current_version_id, dependent: :nullify

  has_one_attached :source_docx_attachment
  has_one_attached :generated_docx_attachment

  enum :status, {
    imported: "imported",
    draft: "draft",
    validated: "validated",
    changed: "changed",
    exported: "exported",
    uploaded_active: "uploaded_active",
    uploaded_inactive: "uploaded_inactive",
    generated_draft: "generated_draft",
    generated_validated: "generated_validated",
    generated_rejected: "generated_rejected",
    approved_active: "approved_active",
    archived: "archived"
  }, default: "imported", suffix: true
end
