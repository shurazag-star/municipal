require "json"
require "digest"

class SemanticMatchAgent
  CONFIDENCE_THRESHOLD = BigDecimal("0.70")
  DECISION_TYPES = AgentMatchDecision::DECISION_TYPES

  def initialize(
    organization:,
    program_version:,
    user: nil,
    analysis_session: nil,
    source_document: nil,
    source_mode: nil,
    llm_client: :default,
    max_candidates: 10
  )
    @organization = organization
    @program_version = program_version
    @user = user
    @analysis_session = analysis_session
    @source_document = source_document
    @source_mode = source_mode
    @setting = AgentSetting.for_organization!(organization)
    @llm_client = llm_client == :default ? default_llm_client : llm_client
    @max_candidates = max_candidates
  end

  def resolve(group:, candidates:, match_candidate: nil, change_item: nil)
    bounded_candidates = normalize_candidates(candidates).first(@max_candidates)
    return unresolved("semantic_agent_unavailable", "LLM-сопоставление недоступно") unless @llm_client
    return unresolved("semantic_agent_no_candidates", "Нет короткого списка кандидатов для LLM") if bounded_candidates.empty?

    input = input_snapshot(group)
    candidate_snapshot = bounded_candidates.map { |candidate| candidate[:snapshot] }
    model = @setting.fast_model.presence || @setting.primary_model
    prompt = user_prompt(input, candidate_snapshot)
    payload = @llm_client.classify(
      system_prompt: system_prompt,
      user_prompt: prompt,
      schema: self.class.schema,
      model: model
    )
    result = normalize_payload(payload, bounded_candidates)
    decision = persist_decision(
      result,
      input: input,
      candidates: candidate_snapshot,
      llm_output: payload.is_a?(Hash) ? payload : {},
      model: model,
      prompt_hash: Digest::SHA256.hexdigest("#{system_prompt}\n#{prompt}"),
      match_candidate: match_candidate,
      change_item: change_item
    )
    result[:agent_match_decision] = decision if decision
    result
  rescue StandardError => error
    result = unresolved("semantic_agent_failed", error.message)
    persist_decision(
      result,
      input: input || input_snapshot(group),
      candidates: candidate_snapshot || [],
      llm_output: { "error" => error.message, "error_class" => error.class.name },
      model: model,
      prompt_hash: prompt ? Digest::SHA256.hexdigest("#{system_prompt}\n#{prompt}") : nil,
      match_candidate: match_candidate,
      change_item: change_item
    )
    result
  end

  def self.schema
    {
      "type" => "object",
      "properties" => {
        "decision_type" => {
          "type" => "string",
          "enum" => DECISION_TYPES
        },
        "selected_program_node_id" => { "type" => ["integer", "null"] },
        "confidence" => { "type" => "number", "minimum" => 0, "maximum" => 1 },
        "reason" => { "type" => "string" },
        "evidence" => { "type" => "array", "items" => { "type" => "string" } },
        "risks" => { "type" => "array", "items" => { "type" => "string" } }
      },
      "required" => %w[decision_type selected_program_node_id confidence reason evidence risks],
      "additionalProperties" => false
    }
  end

  private

  def default_llm_client
    return nil if Rails.env.test?
    return nil unless OpenRouterModelsClient.configured?

    OpenRouterIntentClient.new
  end

  def system_prompt
    <<~PROMPT
      Ты SemanticMatchAgent для муниципальной программы.
      Твоя узкая задача — смысловое сопоставление одной строки внешнего основания с одним из переданных кандидатов DOCX.
      Деньги не считай, суммы не пересчитывай, бюджетную арифметику не объясняй. Код позже проверит математику отдельно.
      Можно выбрать только id из candidate_nodes или вернуть другой decision_type из схемы.
      Если строка похожа на итог, агрегат, справочную или нефинансовую строку, выбери aggregate_only или ignore_not_finance.
      Если данных недостаточно, выбери needs_clarification.
      Если выбранный id не входит в candidate_nodes, решение будет отклонено.
      Верни строго JSON по схеме.
    PROMPT
  end

  def user_prompt(input, candidates)
    JSON.pretty_generate(
      {
        external_row: input,
        candidate_nodes: candidates
      }
    )
  end

  def normalize_payload(payload, candidates)
    payload = JSON.parse(payload) if payload.is_a?(String)
    decision = payload["decision_type"].presence || legacy_decision_type(payload["decision"])
    confidence = BigDecimal(payload["confidence"].to_s)
    reason = payload["reason"].to_s.presence || "Семантическое сопоставление"
    selected_id = payload["selected_program_node_id"].presence || payload["selected_node_id"]
    evidence = Array(payload["evidence"])
    risks = Array(payload["risks"])

    return rejected(decision, "LLM вернула неизвестный тип решения", confidence, evidence, risks) unless decision.in?(DECISION_TYPES)

    if decision.in?(%w[existing_object residual_to_parent])
      selected = candidates.detect { |candidate| candidate[:node].id == selected_id.to_i }
      return rejected(decision, "LLM выбрала id вне списка кандидатов", confidence, evidence, risks) unless selected
      return rejected(decision, reason, confidence, evidence, risks, source: "semantic_agent_low_confidence") if confidence < CONFIDENCE_THRESHOLD

      return {
        status: "matched",
        node: selected[:node],
        confidence: confidence,
        reason: reason,
        source: "semantic_agent",
        decision_type: decision,
        evidence: evidence,
        risks: risks
      }
    end

    {
      status: status_for_decision(decision),
      node: nil,
      confidence: confidence,
      reason: reason,
      source: "semantic_agent",
      decision_type: decision,
      evidence: evidence,
      risks: risks
    }
  rescue JSON::ParserError, ArgumentError
    unresolved("semantic_agent_invalid_response", "LLM вернула невалидное решение")
  end

  def normalize_candidates(candidates)
    Array(candidates).compact.map do |candidate|
      if candidate.is_a?(ProgramNode)
        {
          node: candidate,
          snapshot: {
            "program_node_id" => candidate.id,
            "node_type" => candidate.node_type,
            "display_number" => candidate.display_number,
            "name" => candidate.name,
            "parent_name" => candidate.parent&.name
          }.compact
        }
      else
        node_id = candidate["program_node_id"] || candidate[:program_node_id] || candidate["id"] || candidate[:id]
        node = @program_version.program_nodes.find_by(id: node_id)
        next unless node

        snapshot = candidate.respond_to?(:to_h) ? candidate.to_h.deep_stringify_keys.except("node") : {}
        snapshot["program_node_id"] ||= node.id
        snapshot["node_type"] ||= node.node_type
        snapshot["display_number"] ||= node.display_number
        snapshot["name"] ||= node.name
        snapshot["parent_name"] ||= node.parent&.name
        { node: node, snapshot: snapshot.compact }
      end
    end.compact.uniq { |candidate| candidate[:node].id }
  end

  def input_snapshot(group)
    first_entry = Array(group["funding_entries"]).first || {}
    {
      "object_name" => group["object_name"],
      "object_code" => group["object_code"],
      "event_name" => group["event_name"],
      "group_status" => group["status"],
      "parent_activity_code" => group["parent_activity_code"],
      "residual_parent_name" => group["residual_parent_name"],
      "year" => first_entry["year"],
      "source_type" => first_entry["source_type"],
      "amount_rub" => first_entry["amount_rub"]&.to_s,
      "amount_mode" => first_entry["amount_mode"],
      "text_evidence" => first_entry["evidence_text"].presence || group["evidence_text"],
      "source_document_id" => @source_document&.id,
      "source_document_type" => @source_document&.document_type,
      "source_filename" => @source_document&.filename,
      "source_mode" => SourceModeResolver.normalize(@source_mode || @analysis_session&.effective_source_mode) || "auto"
    }.compact
  end

  def legacy_decision_type(value)
    case value.to_s
    when "existing_object" then "existing_object"
    when "new_object" then "new_object"
    when "residual_row" then "residual_to_parent"
    when "unresolved" then "needs_clarification"
    end
  end

  def status_for_decision(decision)
    case decision
    when "new_object" then "new_object"
    when "aggregate_only", "ignore_not_finance" then "ignored"
    else "unresolved"
    end
  end

  def rejected(decision, reason, confidence, evidence, risks, source: "semantic_agent_rejected")
    {
      status: "unresolved",
      node: nil,
      confidence: confidence,
      reason: reason,
      source: source,
      decision_type: decision,
      evidence: evidence,
      risks: risks
    }
  end

  def persist_decision(result, input:, candidates:, llm_output:, model:, prompt_hash:, match_candidate:, change_item:)
    return nil unless @analysis_session || match_candidate || change_item

    decision_type = result[:decision_type].presence || (result[:status] == "matched" ? "existing_object" : "needs_clarification")
    status = decision_status(result)
    validation = {
      "status" => status,
      "source" => result[:source],
      "reason" => result[:reason],
      "selected_node_valid" => result[:node].present? ? candidates.any? { |candidate| candidate["program_node_id"].to_i == result[:node].id } : nil
    }.compact

    AgentMatchDecision.create!(
      organization: @organization,
      user: @user,
      analysis_session: @analysis_session,
      source_document: @source_document,
      match_candidate: match_candidate,
      change_item: change_item,
      selected_program_node: result[:node],
      decision_type: decision_type,
      status: status,
      confidence: result[:confidence],
      reason: result[:reason],
      input_snapshot: input,
      candidate_snapshot: candidates,
      llm_output: llm_output,
      validation_result: validation,
      model: model,
      prompt_hash: prompt_hash
    )
  end

  def decision_status(result)
    return "accepted" if result[:status] == "matched"
    return "failed" if result[:source].to_s.match?(/failed|invalid|unavailable/)
    return "needs_clarification" if result[:status] == "unresolved"

    "rejected"
  end

  def unresolved(source, reason, confidence: BigDecimal("0"))
    {
      status: "unresolved",
      node: nil,
      confidence: confidence,
      reason: reason,
      source: source,
      decision_type: "needs_clarification",
      evidence: [],
      risks: []
    }
  end
end
