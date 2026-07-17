class ReviewVersion < ApplicationRecord
  has_many :documents, dependent: nil

  scope :newest_first, -> { order(reviewed_at: :desc, project: :asc, topic: :asc, version: :desc) }
  scope :latest_per_topic, -> {
    where("(project, topic, version) IN
           (SELECT project, topic, MAX(version) FROM review_versions GROUP BY project, topic)")
  }
end
