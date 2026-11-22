require "test_helper"

class CostStatsTest < ActiveSupport::TestCase
  def rv(project, topic, version, cost, at, route: "single")
    ReviewVersion.create!(project: project, topic: topic, version: version, path: "#{project}/findings/#{topic}/v#{version}",
                          cost_usd: cost, reviewed_at: at && Time.iso8601(at), route: route)
  end

  setup do
    rv "a", "t1", 1, 1.0, "2026-11-20T10:00:00Z"
    rv "a", "t1", 3, 3.0, "2026-11-21T10:00:00Z"
    rv "a", "t2", 35, 2.0, "2026-11-21T23:30:00Z" # only version: first, despite v35
    rv "a", "t3", 1, nil, "2026-11-01T10:00:00Z", route: nil
    rv "a", "t3", 2, 5.0, "2026-11-21T12:00:00Z", route: "light" # lower version has no cost: still re-review
    rv "b", "t1", 2, 4.0, "2026-11-20T12:00:00Z" # a/t1 v1 is another project: first
    rv "b", "t9", 1, 9.0, nil # no date: skipped
  end

  test "days split first and re-review" do
    s = CostStats.new(ReviewVersion.all)
    assert_equal [Date.new(2026, 11, 21), Date.new(2026, 11, 20)], s.days.map(&:day)

    d21, d20 = s.days
    assert_equal [3, 10.0], [d21.all.count, d21.all.total]
    assert_equal [1, 2.0], [d21.first.count, d21.first.total]
    assert_equal [2, 8.0, 4.0], [d21.rereview.count, d21.rereview.total, d21.rereview.avg]
    assert_equal [2, 5.0, 2.5], [d20.first.count, d20.first.total, d20.first.avg]
    assert_equal 0, d20.rereview.count
    assert_nil d20.rereview.avg
  end

  test "totals and skipped" do
    s = CostStats.new(ReviewVersion.all)
    assert_nil s.totals.day
    assert_equal [5, 15.0, 3.0], [s.totals.all.count, s.totals.all.total, s.totals.all.avg]
    assert_equal [3, 7.0], [s.totals.first.count, s.totals.first.total]
    assert_equal [2, 8.0], [s.totals.rereview.count, s.totals.rereview.total]
    assert_equal 2, s.skipped # a/t3 v1 no cost, b/t9 v1 no date
  end

  test "filtered scope still sees lower versions outside it" do
    s = CostStats.new(ReviewVersion.where(route: "light"))
    assert_equal 1, s.days.size
    assert_equal [0, 1, 5.0], [s.days[0].first.count, s.days[0].rereview.count, s.days[0].rereview.total]
    assert_equal 0, s.skipped
  end

  test "empty scope" do
    s = CostStats.new(ReviewVersion.none)
    assert_empty s.days
    assert_equal 0, s.totals.all.count
    assert_nil s.totals.all.avg
    assert_equal 0, s.skipped
  end
end
