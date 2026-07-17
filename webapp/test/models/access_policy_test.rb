require "test_helper"

class AccessPolicyTest < ActiveSupport::TestCase
  setup do
    AccessPolicy.config = { "auth" => {
      "allowed_domains" => ["percona.com"], "allowed_emails" => ["someone@gmail.com"]
    } }
  end

  teardown { AccessPolicy.config = nil }

  test "domain match" do
    assert AccessPolicy.allowed?("dev@percona.com")
    assert AccessPolicy.allowed?("DEV@PERCONA.COM")
  end

  test "email match" do
    assert AccessPolicy.allowed?("someone@gmail.com")
  end

  test "rejections" do
    refute AccessPolicy.allowed?("other@gmail.com")
    refute AccessPolicy.allowed?("dev@notpercona.com")
    refute AccessPolicy.allowed?(nil)
    refute AccessPolicy.allowed?("")
  end

  test "nil config rejects everyone" do
    policy = Class.new(AccessPolicy)
    def policy.config = nil
    refute policy.allowed?("dev@percona.com")
  end

  test "string without at sign rejected" do
    refute AccessPolicy.allowed?("percona.com")
  end
end
