require "set"

class CandidateObjectFinder
  Result = Struct.new(:status, :node, :candidates, :reason, keyword_init: true)

  def initialize(version:)
    @version = version
  end

  def call(instruction)
    query = instruction["object_ref"].to_s
    return Result.new(status: "needs_clarification", candidates: [], reason: "object_ref_missing") if query.blank?

    candidates = scored_candidates(query, instruction)
    return Result.new(status: "needs_clarification", candidates: [], reason: "object_not_found") if candidates.empty?

    top = candidates.first
    second = candidates.second
    if second && second["score"] >= top["score"] && second["program_node_id"] != top["program_node_id"]
      return Result.new(status: "needs_clarification", candidates: candidates.first(5), reason: "ambiguous_object")
    end

    Result.new(status: "matched", node: @version.program_nodes.find(top["program_node_id"]), candidates: candidates.first(5))
  end

  private

  def scored_candidates(query, instruction)
    query_tokens = tokens(query)
    return [] if query_tokens.empty?

    @version.program_nodes
      .where(node_type: %w[object residual])
      .includes(:parent)
      .filter_map do |node|
        next unless FinancialNodeClassifier.concrete_financial_node?(node)

        score = score_node(node, query_tokens, instruction)
        next if score.zero?

        {
          "program_node_id" => node.id,
          "name" => node.name,
          "display_number" => node.display_number,
          "path" => path_for(node),
          "score" => score
        }
      end
      .sort_by { |candidate| [-candidate["score"], candidate["program_node_id"]] }
  end

  def score_node(node, query_tokens, instruction)
    target = normalize([node.name, node.display_number, node.code].compact.join(" "))
    score = query_tokens.count { |token| target.include?(token.first(6)) }
    score += 2 if normalize(node.name) == normalize(instruction["object_ref"])
    score += path_score(node, instruction)
    score
  end

  def path_score(node, instruction)
    path = normalize(path_for(node).join(" "))
    %w[subprogram_ref main_activity_ref activity_ref].sum do |key|
      ref = normalize(instruction[key])
      ref.present? && path.include?(ref) ? 1 : 0
    end
  end

  def path_for(node)
    path = []
    current = node
    while current
      path.unshift([current.display_number, current.name].compact.join(" "))
      current = current.parent
    end
    path
  end

  def tokens(value)
    normalize(value).split.reject { |token| token.length < 3 || stop_words.include?(token) }
  end

  def normalize(value)
    value.to_s.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def stop_words
    @stop_words ||= %w[объект объекту объекте позиция позиции финансирование строительство реконструкция].to_set
  end
end
