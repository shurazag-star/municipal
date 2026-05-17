class FundingSourceCatalog
  CANONICAL_KEYS = %w[
    FEDERAL_BUDGET
    REGIONAL_BUDGET
    LOCAL_BUDGET
    MUNICIPAL_BUDGET
    EXTRABUDGETARY
    PRIVATE_FUNDS
    OTHER_SOURCE
    UNKNOWN
  ].freeze

  LEGACY_ALIASES = {
    "MOSCOW_OBLAST_BUDGET" => "REGIONAL_BUDGET",
    "MOSCOW_CITY_BUDGET" => "REGIONAL_BUDGET"
  }.freeze

  DEFAULT_LABELS = {
    "FEDERAL_BUDGET" => "Средства федерального бюджета",
    "REGIONAL_BUDGET" => "Средства бюджета субъекта РФ",
    "LOCAL_BUDGET" => "Средства местного бюджета",
    "MUNICIPAL_BUDGET" => "Средства муниципального бюджета",
    "EXTRABUDGETARY" => "Внебюджетные средства",
    "PRIVATE_FUNDS" => "Частные средства",
    "OTHER_SOURCE" => "Иные источники",
    "UNKNOWN" => "Источник не определен"
  }.freeze

  SORT_ORDER = {
    "FEDERAL_BUDGET" => 10,
    "REGIONAL_BUDGET" => 20,
    "LOCAL_BUDGET" => 30,
    "MUNICIPAL_BUDGET" => 40,
    "EXTRABUDGETARY" => 50,
    "PRIVATE_FUNDS" => 60,
    "OTHER_SOURCE" => 70,
    "UNKNOWN" => 99
  }.freeze

  def self.normalize(raw, organization: nil)
    new(organization: organization).normalize(raw)
  end

  def self.label(raw, organization: nil)
    new(organization: organization).label(raw)
  end

  def self.sort_order(raw)
    SORT_ORDER.fetch(canonical_key(raw), 99)
  end

  def self.category_metadata(raw, organization: nil)
    key = normalize(raw, organization: organization)
    {
      "canonical_key" => key,
      "label" => label(key, organization: organization),
      "sort_order" => SORT_ORDER.fetch(key, 99),
      "category" => key.to_s.downcase
    }
  end

  def self.canonical_key(raw)
    key = raw.to_s
    return LEGACY_ALIASES.fetch(key) if LEGACY_ALIASES.key?(key)
    return key if CANONICAL_KEYS.include?(key)

    upcased = key.upcase
    return LEGACY_ALIASES.fetch(upcased) if LEGACY_ALIASES.key?(upcased)
    return upcased if CANONICAL_KEYS.include?(upcased)

    nil
  end

  def initialize(organization: nil)
    @organization = organization
  end

  def normalize(raw)
    explicit = self.class.canonical_key(raw)
    return explicit if explicit

    text = normalize_text(raw)
    return "UNKNOWN" if text.blank?

    alias_match = organization_aliases.detect do |source_alias|
      source_alias.aliases.any? { |item| normalize_text(item) == text } ||
        normalize_text(source_alias.label) == text
    end
    return alias_match.canonical_key if alias_match

    return "FEDERAL_BUDGET" if text.include?("федерал")
    return "PRIVATE_FUNDS" if text.match?(/инвестор|концессион|частн|собственн.*средств/)
    return "EXTRABUDGETARY" if text.include?("внебюдж")
    return "OTHER_SOURCE" if text.match?(/иные? источник|прочие? источник/)
    return "MUNICIPAL_BUDGET" if text.match?(/муниципальн.*район|муниципальн.*образован|муниципальн.*бюджет/)
    return "LOCAL_BUDGET" if text.match?(/местн|городск.*округ|поселен|средства бюджета/)
    return "REGIONAL_BUDGET" if text.match?(/московск|област|краев|республикан|субъект|региональн|ленинградск/)

    "UNKNOWN"
  end

  def label(raw)
    key = normalize(raw)
    organization_label = organization_aliases.find { |source_alias| source_alias.canonical_key == key }&.label
    return organization_label if organization_label.present?
    if key == "LOCAL_BUDGET" && @organization&.municipality_name.present?
      return "Средства бюджета #{municipality_label(@organization.municipality_name)}"
    end

    DEFAULT_LABELS.fetch(key, raw.to_s.presence || DEFAULT_LABELS.fetch("UNKNOWN"))
  end

  private

  def organization_aliases
    return [] unless @organization

    @organization.funding_source_aliases.to_a
  end

  def normalize_text(raw)
    raw.to_s.downcase.tr("ё", "е").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
  end

  def municipality_label(value)
    label = value.to_s.strip
    normalized = normalize_text(label)
    return label if normalized.match?(/округ|район|муниципальн/)

    "муниципального округа #{label}"
  end
end
