class KnowledgeChunk < ApplicationRecord
  belongs_to :organization
  belongs_to :source_document, optional: true

  validates :chunk_type, presence: true
  validates :content, presence: true
end
