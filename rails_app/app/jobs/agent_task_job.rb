class AgentTaskJob < ApplicationJob
  queue_as :default

  def perform(agent_task_id)
    task = AgentTask.find(agent_task_id)
    task.update!(
      status: "running",
      started_at: Time.current,
      finished_at: nil,
      error_message: nil,
      result_payload: (task.result_payload || {}).except("error_class")
    )
    task.update_progress!("Разбираю задачу", "Проверяю загруженные документы и состояние программы.")

    AgentWorkflowRunner.new(
      organization: task.organization,
      user: task.user,
      conversation: task.agent_conversation
    ).perform_task(task)

    task.reload.update!(status: "succeeded", finished_at: Time.current) unless task.failed? || task.cancelled?
  rescue StandardError => error
    Rails.logger.error(
      "[AgentTaskJob] task_id=#{task&.id || agent_task_id} failed: #{error.class}: #{error.message}\n#{error.backtrace&.first(10)&.join("\n")}"
    )
    task&.update!(
      status: "failed",
      error_message: error.message,
      finished_at: Time.current,
      result_payload: (task.result_payload || {}).merge("error_class" => error.class.name)
    )
    task&.agent_conversation&.agent_messages&.create!(
      role: "assistant",
      content: "Не удалось завершить задачу: #{error.message}"
    )
  end
end
