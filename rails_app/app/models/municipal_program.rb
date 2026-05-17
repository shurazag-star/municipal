class MunicipalProgram < ApplicationRecord
  belongs_to :organization
  belongs_to :current_version, class_name: "ProgramVersion", optional: true

  has_many :program_versions, dependent: :destroy
  has_many :municipal_document_profiles, dependent: :destroy

  validates :name, presence: true
end
