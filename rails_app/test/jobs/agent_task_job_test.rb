require "test_helper"
require "securerandom"

class AgentTaskJobTest < ActiveJob::TestCase
  setup do
    @user = create_isolated_user!(email: "agent-task-job-#{SecureRandom.hex(6)}@example.com")
    @organization = @user.organization
    @conversation = AgentConversation.active_for!(organization: @organization, user: @user)
    @user_message = @conversation.agent_messages.create!(
      role: "user",
      user: @user,
      content: "Сформировать DOCX"
    )
    @assistant_message = @conversation.agent_messages.create!(
      role: "assistant",
      content: "Принял задачу."
    )
  end

  test "records failure without re-raising for sidekiq retry loop" do
    task = @conversation.agent_tasks.create!(
      organization: @organization,
      user: @user,
      agent_message: @user_message,
      assistant_message: @assistant_message,
      status: "queued",
      task_type: "export",
      input_message: "Сформировать DOCX",
      progress_payload: { "intent" => "generate_docx" }
    )
    failing_runner = Object.new
    def failing_runner.perform_task(_task)
      raise TypeError, "no implicit conversion of String into Integer"
    end

    original_new = AgentWorkflowRunner.method(:new)
    AgentWorkflowRunner.define_singleton_method(:new) { |**_kwargs| failing_runner }

    begin
      assert_nothing_raised do
        AgentTaskJob.perform_now(task.id)
      end
    ensure
      AgentWorkflowRunner.define_singleton_method(:new, original_new)
    end

    task.reload
    assert_equal "failed", task.status
    assert_equal "no implicit conversion of String into Integer", task.error_message
    assert_equal "TypeError", task.result_payload["error_class"]
    assert @conversation.agent_messages.where(role: "assistant").where("content LIKE ?", "%Не удалось завершить задачу%").exists?
  end
end
