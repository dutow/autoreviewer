require "test_helper"

class IndexerTest < ActiveSupport::TestCase
  test "full reindex populates versions documents and fts" do
    with_reviews_root do |root, _|
      Indexer.new(root: root).run
      assert_equal 3, ReviewVersion.count
      v2 = ReviewVersion.find_by!(project: "alpha", topic: "t1", version: 2)
      assert_equal "Fix qual pushdown", v2.title
      assert_equal Time.utc(2026, 6, 1, 10), v2.reviewed_at
      assert v2.documents.exists?(relpath: "patches/fix.patch", kind: "patch")
      refute v2.documents.exists?(relpath: "tests/blob.bin")
      hits = Document.search("frobnicator")
      assert(hits.any? { |h| h[:document].review_version.topic == "pr5" })
    end
  end

  test "finding counts from findings json" do
    with_reviews_root do |root, dir|
      Indexer.new(root: root).run
      v2 = ReviewVersion.find_by!(project: "alpha", topic: "t1", version: 2)
      assert_equal [1, 0, 2, 0, 3, 0, 2, 4, 1],
                   v2.values_at(:bug_count, :likely_bug_count, :suspicious_count, :risky_count,
                                :nitpick_count, :typo_count, :post_count, :fyi_count, :withdrawn_count)
      assert_equal "bug", v2.worst_severity
      v1 = ReviewVersion.find_by!(project: "alpha", topic: "t1", version: 1)
      refute v1.counts?
      assert_nil v1.worst_severity
      refute Document.exists?(relpath: "findings.json")

      ReviewsFixture.commit_change(dir, "alpha/findings/t1/v2/findings.json",
                                   '{"severity": {"BUG": 0, "LIKELY_BUG": "x"}}')
      Indexer.new(root: root).run
      v2.reload
      assert_equal [0, 0, 0], v2.values_at(:bug_count, :likely_bug_count, :post_count)
    end
  end

  test "usage from usage json" do
    with_reviews_root do |root, dir|
      Indexer.new(root: root).run
      v2 = ReviewVersion.find_by!(project: "alpha", topic: "t1", version: 2)
      assert_in_delta 1.234, v2.cost_usd
      assert_equal 1010, v2.total_tokens
      assert_equal "single", v2.route
      v1 = ReviewVersion.find_by!(project: "alpha", topic: "t1", version: 1)
      assert_nil v1.cost_usd
      assert_nil v1.total_tokens
      assert_nil v1.route
      refute Document.exists?(relpath: "usage.json")

      ReviewsFixture.commit_change(dir, "alpha/findings/t1/v2/usage.json", '{"total": {"cost_usd": "x", "tokens": []}}')
      Indexer.new(root: root).run
      v2.reload
      assert_nil v2.cost_usd
      assert_nil v2.route
    end
  end

  test "fallbacks for version without metadata" do
    with_reviews_root do |root, _|
      Indexer.new(root: root).run
      v1 = ReviewVersion.find_by!(project: "alpha", topic: "t1", version: 1)
      assert_nil v1.title
      assert_not_nil v1.reviewed_at   # from git log
    end
  end

  test "failed diff falls back to full reindex" do
    with_reviews_root do |root, _|
      IndexState.set("head", "0" * 40) # unknown sha -> git diff fails
      Indexer.new(root: root).run
      assert_equal 3, ReviewVersion.count
      assert Document.search("frobnicator").any?
    end
  end

  test "noop when head unchanged" do
    with_reviews_root do |root, _|
      Indexer.new(root: root).run
      before = ReviewVersion.first.updated_at
      Indexer.new(root: root).run
      assert_equal before, ReviewVersion.first.updated_at
    end
  end

  test "incremental picks up new version and prunes deleted" do
    with_reviews_root do |root, dir|
      Indexer.new(root: root).run
      ReviewsFixture.commit_change(dir, "alpha/findings/t1/v3/00-overview.md",
                                   "# Patch Overview: t1 v3\n\nzanzibar content\n")
      Indexer.new(root: root).run
      assert ReviewVersion.exists?(project: "alpha", topic: "t1", version: 3)
      assert Document.search("zanzibar").any?

      FileUtils.rm_rf(File.join(dir, "alpha/findings/t1/v3"))
      system("git", "-C", dir, "add", "-A", exception: true)
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t",
             "commit", "-qm", "rm", exception: true)
      Indexer.new(root: root).run
      refute ReviewVersion.exists?(project: "alpha", topic: "t1", version: 3)
      assert_empty Document.search("zanzibar")
    end
  end
end
