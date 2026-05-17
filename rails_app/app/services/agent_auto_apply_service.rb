class AgentAutoApplyService
  Result = Struct.new(:status, :change_set, :tool_result, :resolution, keyword_init: true)

  def initialize(organization:, user:)
    @organization = organization
    @user = user
    @registry = AgentToolRegistry.new(organization: organization, user: user)
  end

  def call(context:)
    analysis_result = ensure_change_project(context)
    return Result.new(status: analysis_result["status"], tool_result: analysis_result) unless analysis_result["status"] == "completed"

    change_set = latest_change_set
    return Result.new(status: "empty", tool_result: { "status" => "empty" }) unless change_set

    resolution = AgentAutonomousResolver.new(change_set: change_set, user: @user).resolve!
    if resolution.needs_clarification_count.positive?
      return Result.new(
        status: "needs_clarification",
        change_set: change_set.reload,
        resolution: resolution,
        tool_result: unresolved_payload(change_set.reload, resolution)
      )
    end

    export_result = @registry.execute("generate_docx", context: refreshed_context, arguments: {})
    Result.new(status: export_result["status"], change_set: change_set.reload, resolution: resolution, tool_result: export_result)
  end

  private

  def ensure_change_project(context)
    if context.dig("latest_change_set", "loaded")
      { "status" => "completed", "reused" => true, "change_project_id" => context.dig("latest_change_set", "id") }
    else
      @registry.execute("run_analysis", context: context, arguments: {})
    end
  end

  def refreshed_context
    AgentContextBuilder.new(organization: @organization, user: @user).build
  end

  def latest_change_set
    ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: @organization.id })
      .order(updated_at: :desc)
      .first
  end

  def unresolved_payload(change_set, resolution)
    {
      "status" => "needs_clarification",
      "change_project_id" => change_set.id,
      "change_set_id" => change_set.id,
      "resolved_count" => resolution.resolved_count,
      "excluded_count" => resolution.excluded_count,
      "needs_clarification_count" => resolution.needs_clarification_count,
      "pending_items" => change_set.change_items
        .where(agent_resolution_status: "needs_clarification")
        .order(:id)
        .limit(10)
        .map { |item| AgentToolRegistry.change_item_public_summary(item) }
    }
  end
end
