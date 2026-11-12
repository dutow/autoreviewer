class ReviewVersion < ApplicationRecord
  has_many :documents, dependent: nil

  scope :newest_first, -> { order(reviewed_at: :desc, project: :asc, topic: :asc, version: :desc) }
  scope :latest_per_topic, -> {
    where("(project, topic, version) IN
           (SELECT project, topic, MAX(version) FROM review_versions GROUP BY project, topic)")
  }

  SEVERITIES = %w[bug likely_bug suspicious risky nitpick typo].freeze
  # filter name -> severities that satisfy it
  MIN_SEVERITY = { "bug" => %w[bug], "likely_bug" => %w[bug likely_bug] }.freeze

  scope :min_severity, ->(min) {
    sevs = MIN_SEVERITY[min]
    next all unless sevs

    sevs.map { |s| where("#{s}_count > 0") }.reduce(:or)
  }

  def counts? = !bug_count.nil?

  def worst_severity
    SEVERITIES.find { |s| self["#{s}_count"].to_i > 0 }
  end
end
