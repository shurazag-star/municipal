class AgentTask < ApplicationRecord
  belongs_to :organization
  belongs_to :user
  belongs_to :agent_conversation
  belongs_to :agent_message, optional: true
  belongs_to :assistant_message, class_name: "AgentMessage", optional: true

  enum :status, {
    queued: "queued",
    running: "running",
    succeeded: "succeeded",
    failed: "failed",
    cancelled: "cancelled"
  }, default: "queued"

  enum :task_type, {
    analysis: "analysis",
    autonomous_resolution: "autonomous_resolution",
    export: "export",
    full_workflow: "full_workflow"
  }, default: "full_workflow"

  def update_progress!(step, detail = nil, payload = {})
    update!(
      progress_payload: (progress_payload || {}).merge(
        "step" => step,
        "detail" => detail,
        "updated_at" => Time.current.iso8601
      ).merge(payload)
    )
  end
end
