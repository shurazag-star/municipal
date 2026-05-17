class User < ApplicationRecord
  belongs_to :organization, optional: true
  has_many :manual_change_instructions, dependent: :nullify

  has_secure_password

  enum :role, { user: "user", admin: "admin" }, default: "user"

  validates :email, presence: true, uniqueness: true
end
