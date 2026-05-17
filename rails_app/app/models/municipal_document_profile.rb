class MunicipalDocumentProfile < ApplicationRecord
  belongs_to :organization
  belongs_to :municipal_program, optional: true
  belongs_to :source_document, optional: true

  enum :status, {
    draft: "draft",
    active: "active",
    failed: "failed"
  }, default: "draft"

  enum :profile_type, {
    docx_program: "docx_program",
    xlsx_finance: "xlsx_finance",
    procedure: "procedure",
    pdf_agreement: "pdf_agreement"
  }

  validates :profile_type, presence: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }

  def payload
    schema_json || {}
  end

  def issues
    Array(warnings)
  end

  def passport_table
    payload["passport_table"] || payload.dig("municipal_document_profile", "passport_table") || {}
  end

  def finance_tables
    payload["docx_finance_tables"] || payload.dig("municipal_document_profile", "finance_tables") || []
  end

  def money_units
    payload["units"] || payload.dig("municipal_document_profile", "money_units") || {}
  end
end
