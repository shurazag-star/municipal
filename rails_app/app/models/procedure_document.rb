class ProcedureDocument < ApplicationRecord
  belongs_to :organization
  belongs_to :created_by, class_name: "User"

  has_one_attached :file_attachment
end

