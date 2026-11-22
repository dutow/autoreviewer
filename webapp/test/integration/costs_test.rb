require "test_helper"

class CostsTest < ActionDispatch::IntegrationTest
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

  def cells = css_select("table.costs tbody tr td").map { |c| c.text.strip }

  test "per-day row and skipped" do
    get "/costs"
    assert_response :success
    assert_select "header.topbar a.nav[href='/costs']", text: "Costs"
    assert_equal ["2026-06-01", "1", "$1.23", "$1.23", "0", "$0.00", "-", "1", "$1.23", "$1.23"], cells
    assert_equal "all days", css_select("table.costs tfoot td").first.text.strip
    assert_select "p.skipped", text: "2 reviews not counted (no cost data)"
  end

  test "project and route filters" do
    get "/costs?project=beta"
    assert_empty cells
    assert_select "p.skipped", text: "1 review not counted (no cost data)"
    assert_select "nav.filters a.active", text: "beta"

    get "/costs?route=single"
    assert_equal "1", cells[1]
    assert_select "nav.filters a.active", text: "single"
  end

  test "unknown filter values render empty" do
    get "/costs?project=nope&route=nope"
    assert_response :success
    assert_empty cells
  end
end
