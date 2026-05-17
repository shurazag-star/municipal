class FundingSourceAlias < ApplicationRecord
  belongs_to :organization

  validates :canonical_key, presence: true
  validates :label, presence: true
  validates :canonical_key, uniqueness: { scope: :organization_id }
  validate :canonical_key_is_supported

  private

  def canonical_key_is_supported
    return if FundingSourceCatalog::CANONICAL_KEYS.include?(canonical_key.to_s)

    errors.add(:canonical_key, "is not supported")
  end
end
