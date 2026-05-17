class SemanticMatchDecisionApplier
  def initialize(change_item:)
    @change_item = change_item
  end

  def apply!
    decision = decision_for_item
    return nil unless decision

    validation = validation_for(decision)
    if validation["passed"]
      decision.update!(
        change_item: @change_item,
        validation_result: decision.validation_result.merge(validation),
        status: "accepted"
      )
    else
      decision.update!(
        change_item: @change_item,
        validation_result: decision.validation_result.merge(validation),
        status: "rejected"
      )
      @change_item.update!(
        agent_resolution_status: "needs_clarification",
        agent_resolution_reason: validation["reason"],
        requires_user_confirmation: true
      )
    end
    decision
  end

  private

  def decision_for_item
    id = @change_item.source_reference.to_h["agent_match_decision_id"].presence
    return nil unless id

    AgentMatchDecision.find_by(id: id)
  end

  def validation_for(decision)
    if decision.decision_type.in?(%w[existing_object residual_to_parent])
      return failed("Семантическое решение не содержит выбранный объект программы") unless decision.selected_program_node_id
      return failed("Семантическое решение привязано к другому объекту программы") if @change_item.program_node_id.to_i != decision.selected_program_node_id.to_i
    end

    if decision.confidence.present? && decision.confidence < SemanticMatchAgent::CONFIDENCE_THRESHOLD
      return failed("Уверенность семантического решения ниже порога")
    end

    {
      "passed" => true,
      "applied_to_change_item_id" => @change_item.id,
      "validated_at" => Time.current.iso8601
    }
  end

  def failed(reason)
    {
      "passed" => false,
      "reason" => reason,
      "applied_to_change_item_id" => @change_item.id,
      "validated_at" => Time.current.iso8601
    }
  end
end
