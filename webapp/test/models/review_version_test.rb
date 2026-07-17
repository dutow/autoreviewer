require "test_helper"

class ReviewVersionTest < ActiveSupport::TestCase
  test "latest_per_topic keeps only max version per topic" do
    ReviewVersion.create!(project: "alpha", topic: "t1", version: 1, path: "alpha/findings/t1/v1")
    ReviewVersion.create!(project: "alpha", topic: "t1", version: 2, path: "alpha/findings/t1/v2")
    ReviewVersion.create!(project: "beta", topic: "pr9", version: 3, path: "beta/findings/pr9/v3")

    got = ReviewVersion.latest_per_topic.pluck(:project, :topic, :version).sort
    assert_equal [["alpha", "t1", 2], ["beta", "pr9", 3]], got
  end

  test "latest_per_topic composes with project filter" do
    ReviewVersion.create!(project: "gamma", topic: "t2", version: 1, path: "gamma/findings/t2/v1")
    ReviewVersion.create!(project: "gamma", topic: "t2", version: 2, path: "gamma/findings/t2/v2")
    ReviewVersion.create!(project: "delta", topic: "pr10", version: 3, path: "delta/findings/pr10/v3")

    got = ReviewVersion.latest_per_topic.where(project: "gamma").pluck(:topic, :version)
    assert_equal [["t2", 2]], got
  end
end
