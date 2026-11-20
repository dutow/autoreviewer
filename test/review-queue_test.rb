require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

load File.expand_path('../bin/review-queue', __dir__)

class ReviewQueuePauseTest < Minitest::Test
  ENV_KEYS = %w[STATE_DIR WORKSPACE_DIR REVIEW_QUEUE_FILE REVIEW_QUEUE_PROCESSED].freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    ENV_KEYS.each { |k| ENV.delete(k) }
    @dir = Dir.mktmpdir
    ENV['STATE_DIR'] = File.join(@dir, 'state')
    ENV['WORKSPACE_DIR'] = File.join(@dir, 'ws')
    @path = File.join(@dir, 'state', 'paused')
    @pause = ReviewRun::Pause.new(@path)
    @queue = ReviewQueue.new
    @now = Time.at(1_800_000_000)
  end

  def teardown
    FileUtils.rm_rf(@dir)
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def until_line(t)
    /\A\[\d\d:\d\d:\d\d\] paused until #{Regexp.escape(t.strftime('%Y-%m-%d %H:%M:%S'))} \(usage limit\)\n\z/
  end

  def test_not_paused_without_file
    out, = capture_io { refute @queue.paused_now?(@now) }
    assert_empty out
  end

  def test_paused_prints_once_per_pause
    @pause.set(@now + 600, by: 'p-t1')
    out, = capture_io do
      assert @queue.paused_now?(@now)
      assert @queue.paused_now?(@now + 30)
      assert @queue.paused_now?(@now + 60)
    end
    assert_match until_line(@now + 600), out

    @pause.set(@now + 1200, by: 'p-t2')
    out, = capture_io { assert @queue.paused_now?(@now + 90) }
    assert_match until_line(@now + 1200), out
  end

  def test_expired_pause_removed_and_next_pause_printed
    @pause.set(@now + 600, by: 'p-t1')
    capture_io { assert @queue.paused_now?(@now) }
    out, = capture_io { refute @queue.paused_now?(@now + 600) }
    assert_empty out
    refute File.exist?(@path)

    @pause.set(@now + 600, by: 'p-t1')
    out, = capture_io { assert @queue.paused_now?(@now + 10) }
    assert_match until_line(@now + 600), out
  end

  def test_corrupt_pause_file_ignored
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, '{')
    out, = capture_io { refute @queue.paused_now?(@now) }
    assert_empty out
    refute File.exist?(@path)
  end
end
