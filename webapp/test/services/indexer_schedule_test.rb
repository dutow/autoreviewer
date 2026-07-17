require "test_helper"

class IndexerScheduleTest < ActiveSupport::TestCase
  test "run_if_stale throttles head checks" do
    Indexer.instance_variable_set(:@last_check, Time.at(0))
    first = Indexer.run_if_stale
    assert_kind_of Thread, first
    first.join
    assert_nil Indexer.run_if_stale # throttled: within CHECK_INTERVAL
  ensure
    Indexer.instance_variable_set(:@last_check, Time.at(0))
  end

  test "synchronized_run swallows and logs errors" do
    broken_root = Object.new
    def broken_root.git_head = raise("boom")
    broken = Indexer.allocate
    broken.instance_variable_set(:@root, broken_root)

    Indexer.define_singleton_method(:new) { |*| broken }
    assert_nothing_raised { Indexer.synchronized_run }
  ensure
    Indexer.singleton_class.send(:remove_method, :new)
  end

  test "reindexer timer is gated behind the server hook" do
    # Server blocks only run via Rails.application.load_server in config.ru,
    # which console/runner/rake never evaluate. Tripwire: keep the initializer
    # on the server-hook API and keep config.ru loading the server blocks.
    initializer = Rails.root.join("config/initializers/reindexer.rb").read
    assert_match(/Rails\.application\.server do/, initializer)
    refute_match(/after_initialize/, initializer)
    assert_match(/Rails\.application\.load_server/, Rails.root.join("config.ru").read)
  end
end
