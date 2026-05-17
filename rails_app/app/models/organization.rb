class Organization < ApplicationRecord
  has_many :users, dependent: :nullify
  has_many :municipal_programs, dependent: :destroy
  has_many :program_versions, through: :municipal_programs
  has_many :source_documents, dependent: :destroy
  has_many :procedure_documents, dependent: :destroy
  has_many :knowledge_chunks, dependent: :destroy
  has_many :analysis_sessions, dependent: :destroy
  has_many :agent_tasks, dependent: :destroy
  has_one :agent_setting, dependent: :destroy
  has_many :agent_conversations, dependent: :destroy
  has_many :funding_source_aliases, dependent: :destroy
  has_many :municipal_document_profiles, dependent: :destroy
  has_many :manual_change_instructions, dependent: :destroy

  validates :name, presence: true
end
