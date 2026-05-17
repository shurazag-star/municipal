class Reconciliation < ApplicationRecord
  belongs_to :program_version
  belongs_to :source_document
  belongs_to :program_node, optional: true
end

