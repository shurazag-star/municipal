class ProgramNode < ApplicationRecord
  belongs_to :program_version
  belongs_to :parent, class_name: "ProgramNode", optional: true
  has_many :children, class_name: "ProgramNode", foreign_key: :parent_id, dependent: :destroy, inverse_of: :parent
  has_many :funding_lines, dependent: :destroy
  has_many :reconciliations, dependent: :destroy
  has_many :match_candidates, dependent: :nullify
  has_many :change_items, dependent: :nullify
  has_many :agent_match_decisions,
    foreign_key: :selected_program_node_id,
    dependent: :nullify,
    inverse_of: :selected_program_node
  has_many :manual_change_instructions, dependent: :nullify

  enum :node_type, {
    program: "program",
    subprogram: "subprogram",
    main_activity: "main_activity",
    activity: "activity",
    object: "object",
    result: "result",
    residual: "residual"
  }
end
