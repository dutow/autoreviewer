require "test_helper"

class AuthTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    AccessPolicy.config = { "auth" => {
      "allowed_domains" => ["percona.com"], "allowed_emails" => []
    } }
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    AccessPolicy.config = nil
  end

  def mock_login(email)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "123", info: { email: email }
    )
    post "/auth/google_oauth2"
    follow_redirect! # to the callback
  end

  test "unauthenticated gets login page" do
    get "/"
    assert_response :unauthorized
    assert_select "form[action=?]", "/auth/google_oauth2"
  end

  test "AUTH_MODE=none skips login" do
    ENV["AUTH_MODE"] = "none"
    get "/"
    assert_response :success
  ensure
    ENV.delete("AUTH_MODE")
  end

  test "stale local session rejected after AUTH_MODE flips back" do
    ENV["AUTH_MODE"] = "none"
    get "/"
    assert_response :success

    ENV.delete("AUTH_MODE")
    get "/"
    assert_response :unauthorized
  ensure
    ENV.delete("AUTH_MODE")
  end

  test "allowed email signs in and browses" do
    mock_login("dev@percona.com")
    follow_redirect!
    assert_response :success
    get "/"
    assert_response :success
  end

  test "disallowed email gets 403" do
    mock_login("evil@example.com")
    assert_response :forbidden
    get "/"
    assert_response :unauthorized
  end

  test "logout clears session" do
    mock_login("dev@percona.com")
    delete "/logout"
    get "/"
    assert_response :unauthorized
  end

  test "health check open" do
    get "/up"
    assert_response :success
  end

  test "oauth failure renders login with humanized message" do
    get "/auth/failure", params: { message: "invalid_credentials" }
    assert_response :unauthorized
    assert_select "p.alert", /Invalid credentials/
  end
end
