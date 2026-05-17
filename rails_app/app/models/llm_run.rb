class LlmRun < ApplicationRecord
  belongs_to :organization
  belongs_to :user, optional: true
end

