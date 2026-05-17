class AuditLog < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :organization, optional: true
  belongs_to :auditable, polymorphic: true, optional: true

  def self.record!(user, organization, action, auditable = nil, payload = {})
    create!(
      user: user,
      organization: organization,
      action: action,
      auditable: auditable,
      payload: payload
    )
  end
end
