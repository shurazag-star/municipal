class SourceDocument < ApplicationRecord
  belongs_to :organization
  belongs_to :created_by, class_name: "User"

  has_many :match_candidates, dependent: :destroy
  has_many :excel_rows, dependent: :destroy
  has_many :funding_lines, dependent: :nullify
  has_many :change_sets, dependent: :nullify
  has_many :reconciliations, dependent: :destroy
  has_many :knowledge_chunks, dependent: :destroy
  has_many :municipal_document_profiles, dependent: :destroy
  has_many :agent_match_decisions, dependent: :nullify

  has_one_attached :file_attachment

  enum :document_type, {
    docx_program: "docx_program",
    pdf_procedure: "pdf_procedure",
    xlsx_finance: "xlsx_finance",
    pdf_agreement: "pdf_agreement",
    other: "other"
  }, default: "other"
end
