require "test_helper"

class BrowseTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    AccessPolicy.config = { "auth" => { "allowed_domains" => ["percona.com"], "allowed_emails" => [] } }
    @reviews_dir = ReviewsFixture.create
    @old_root = ENV["REVIEWS_ROOT"]
    ENV["REVIEWS_ROOT"] = @reviews_dir
    IndexState.delete_all
    Indexer.new(root: ReviewsRoot.new(path: @reviews_dir)).run(full: true)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "1", info: { email: "dev@percona.com" }
    )
    post "/auth/google_oauth2"
    follow_redirect!
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    AccessPolicy.config = nil
    ENV["REVIEWS_ROOT"] = @old_root
    FileUtils.remove_entry(@reviews_dir)
  end

  test "home table newest first with filter" do
    get "/"
    assert_response :success
    topics = css_select("table.reviews tbody tr td:nth-child(2) a").map(&:text)
    assert_equal %w[pr5 t1], topics,
                 "latest only by default: one row per topic, pr5 (2026-06-15) above t1 v2 (2026-06-01)"
    get "/?project=alpha"
    assert_select "td", text: /t1/
    assert_select "td", { text: /pr5/, count: 0 }
  end

  test "versions=all shows every version and marks toggle active" do
    get "/?versions=all"
    topics = css_select("table.reviews tbody tr td:nth-child(2) a").map(&:text)
    assert_equal %w[pr5 t1 t1], topics
    assert_select "nav.filters a.active", text: "all versions"
    get "/"
    assert_select "nav.filters a.active", text: "latest"
  end

  test "project page latest only by default with toggle" do
    get "/p/alpha"
    assert_select "table.reviews tbody tr", count: 1
    assert_select "tbody td a", text: "v2"
    get "/p/alpha?versions=all"
    assert_select "table.reviews tbody tr", count: 2
  end

  test "home renders with no indexed reviews" do
    Document.delete_all
    ReviewVersion.delete_all
    get "/"
    assert_response :success
    assert_select "table.reviews tbody tr", count: 0
  end

  test "project page renders and topic redirects to default file" do
    get "/p/alpha"
    assert_response :success
    get "/p/alpha/t/t1"
    assert_redirected_to "/p/alpha/t/t1/v/2/f/00-overview.md"
    get "/p/alpha/t/nope"
    assert_response :not_found
  end

  test "version redirects to its default file" do
    get "/p/alpha/t/t1/v/2"
    assert_redirected_to "/p/alpha/t/t1/v/2/f/00-overview.md"
    get "/p/alpha/t/t1/v/1"
    assert_redirected_to "/p/alpha/t/t1/v/1/f/00-overview.md"
  end

  test "file rendering by kind" do
    get "/p/alpha/t/t1/v/2/f/00-overview.md"
    assert_response :success
    assert_select "article.markdown h1"
    get "/p/alpha/t/t1/v/2/f/patches/fix.patch"
    assert_select "pre.diff span.diff-add"
    get "/p/beta/t/pr5/v/1/f/discussion.txt"
    assert_select "pre.plain"
    get "/p/alpha/t/t1/v/2/f/tests/blob.bin"
    assert_equal "application/octet-stream", response.media_type
  end

  test "standalone code files are highlighted by extension" do
    dir = File.join(@reviews_dir, "alpha/findings/t1/v2/tests")
    File.write(File.join(dir, "query.sql"), "SELECT 1;\n")
    File.write(File.join(dir, "big.sql"), "SELECT 1;\n" * 60_000)

    get "/p/alpha/t/t1/v/2/f/tests/query.sql"
    assert_response :success
    assert_select "pre.highlight code span.k", text: "SELECT"
    assert_select "pre.plain", count: 0

    get "/p/alpha/t/t1/v/2/f/tests/big.sql"
    assert_response :success
    assert_select "pre.plain"

    get "/p/beta/t/pr5/v/1/f/discussion.txt"
    assert_select "pre.plain"
  end

  test "traversal and unknowns 404" do
    get "/p/alpha/t/t1/v/2/f/..%2F..%2Ft1%2Fv1%2F00-overview.md"
    assert_response :not_found
    get "/p/alpha/t/t1/v/99"
    assert_response :not_found
    get "/p/_template"
    assert_response :not_found
  end

  test "requires login" do
    delete "/logout"
    get "/p/alpha/t/t1/v/2"
    assert_response :unauthorized
  end

  test "javascript urls in metadata are not linked" do
    File.write(File.join(@reviews_dir, "alpha/findings/t1/v2/metadata.json"), <<~JSON)
      { "title": "Fix qual pushdown", "source_url": "javascript:alert(1)",
        "hackorum_url": "javascript:alert(2)", "reviewed_at": "2026-06-01T10:00:00Z" }
    JSON
    Indexer.new(root: ReviewsRoot.new(path: @reviews_dir)).run(full: true)

    ["/", "/p/alpha", "/p/alpha/t/t1/v/2/f/00-overview.md"].each do |path|
      get path
      assert_response :success
      assert_select "a[href^=javascript]", count: 0
    end
    get "/p/beta/t/pr5"
    follow_redirect!
    assert_select "a[href=?]", "https://github.com/acme/beta/pull/5"
  end

  test "viewer sidebar shows toc files and versions" do
    get "/p/alpha/t/t1/v/2/f/00-overview.md"
    assert_response :success
    assert_select ".side details.toc a[href^='#']", text: "Patch Overview: t1 v2"
    assert_select ".side details.files a.active", text: /00-overview\.md/
    assert_select ".side details.files a", text: /fix\.patch/
    assert_select ".side details.files a", { text: /metadata\.json/, count: 0 }
    assert_select ".side details.versions a.active", text: /v2/
    assert_select ".side details.versions a[href=?]", "/p/alpha/t/t1/v/1"
    assert_select ".crumbs a", text: "raw"
  end

  test "layout has theme toggle and app js" do
    get "/"
    assert_select "button#theme-toggle"
    assert_select "script[src*='app']"
  end

  test "pagination limits table and clamps page" do
    create_bulk(30)
    get "/"
    assert_select "table.reviews tbody tr", count: 25
    assert_select "nav.pager a.active", text: "1"
    get "/?page=2"
    assert_select "table.reviews tbody tr", count: 7
    get "/?page=999"
    assert_select "table.reviews tbody tr", count: 7
    assert_select "nav.pager a.active", text: "2"
    get "/?page=abc"
    assert_select "table.reviews tbody tr", count: 25
    get "/?page[]=1"
    assert_response :success
    assert_select "table.reviews tbody tr", count: 25
    get "/?action=destroy&host=evil.com&page=1"
    assert_response :success
    assert_select "nav.pager a[href*='evil.com']", count: 0
  end

  test "pager preserves filters and hides on single page" do
    get "/"
    assert_select "nav.pager", count: 0
    create_bulk(30)
    get "/?project=bulk&page=2"
    assert_select "table.reviews tbody tr", count: 5
    assert_select "nav.pager a[href*='project=bulk']"
    get "/?versions=all&page=2"
    assert_select "nav.pager a[href*='versions=all']"
  end

  test "project page pager recalls path and preserves versions" do
    create_bulk(30, project: "alpha")
    get "/p/alpha?page=2"
    assert_select "table.reviews tbody tr", count: 6
    assert_select "nav.pager a[href^='/p/alpha?']"
    get "/p/alpha?versions=all&page=2"
    assert_select "nav.pager a[href*='versions=all']"
  end

  private

  def create_bulk(n, project: "bulk")
    n.times do |i|
      ReviewVersion.create!(project: project, topic: format("topic%02d", i), version: 1,
                            path: "#{project}/findings/topic#{i}/v1",
                            reviewed_at: Time.utc(2026, 1, 1) + i.hours)
    end
  end
end
