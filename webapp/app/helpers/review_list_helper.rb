module ReviewListHelper
  LIST_PARAMS = %w[project versions min].freeze

  SEVERITY_LABELS = {
    "bug" => "BUG", "likely_bug" => "LIKELY", "suspicious" => "SUSP",
    "risky" => "RISKY", "nitpick" => "NIT", "typo" => "TYPO"
  }.freeze

  # current list url with overrides, nil drops a param; page not kept
  def list_url(overrides = {})
    url_for(request.query_parameters.slice(*LIST_PARAMS).merge(overrides.stringify_keys).compact)
  end

  def finding_badges(r)
    return tag.span("-", class: "dim") unless r.counts?

    badges = SEVERITY_LABELS.filter_map do |sev, label|
      n = r["#{sev}_count"].to_i
      tag.span("#{n} #{label}", class: "sev sev-#{sev.dasherize}", title: "#{n} #{sev.humanize(capitalize: false)}") if n > 0
    end
    return tag.span("none", class: "dim") if badges.empty?

    badges << tag.span("#{r.post_count} to post", class: "dim") if r.post_count.to_i > 0
    safe_join(badges, " ")
  end

  def usage_cost(r)
    r.cost_usd ? format("$%.2f", r.cost_usd) : ""
  end

  def review_row_class(r)
    sev = r.worst_severity
    "row-#{sev.dasherize}" if %w[bug likely_bug].include?(sev)
  end
end
