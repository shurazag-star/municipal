class ExcelRow < ApplicationRecord
  belongs_to :source_document
  has_many :match_candidates, dependent: :nullify
end
