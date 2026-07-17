require "test_helper"

class SearchTest < ActionDispatch::IntegrationTest
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

  test "finds documents with snippet" do
    get "/search", params: { q: "frobnicator" }
    assert_response :success
    assert_select "mark", text: /frobnicator/i
    assert_select "a[href*=?]", "/p/beta/t/pr5/v/1/f/"
  end

  test "snippet content is html escaped" do
    File.write(File.join(@reviews_dir, "alpha/findings/t1/v2/03-evil.md"),
               "# Evil\n\nxss vector <img src=x onerror=alert(1)> near quokka keyword\n")
    IndexState.delete_all
    Indexer.new(root: ReviewsRoot.new(path: @reviews_dir)).run(full: true)
    get "/search", params: { q: "quokka" }
    assert_response :success
    assert_select "mark", text: /quokka/i
    refute_match(/<img src=x/, response.body)
  end

  test "hostile query does not error" do
    get "/search", params: { q: %q{"unbalanced (AND NEAR/3} }
    assert_response :success
  end

  test "empty query shows form only" do
    get "/search"
    assert_response :success
    assert_select ".hit", count: 0
  end

  test "requires login" do
    delete "/logout"
    get "/search", params: { q: "frobnicator" }
    assert_response :unauthorized
  end
end
