require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'time'

require_relative '../../lib/review_run/pause'

class PauseTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, 'state', 'paused')
    @pause = ReviewRun::Pause.new(@path)
    @now = Time.at(1_800_000_000)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_set_writes_json
    @pause.set(@now + 60, by: 'p-t1')
    assert_equal({ 'until' => (@now + 60).iso8601, 'by' => 'p-t1' }, JSON.parse(File.read(@path)))
    assert_equal @now + 60, @pause.until_time
    assert_equal [File.basename(@path)], Dir.children(File.dirname(@path))
  end

  def test_active_until_time_passes
    @pause.set(@now + 60, by: 'p-t1')
    assert @pause.active?(@now)
    assert @pause.active?(@now + 59)
    assert File.exist?(@path)
    refute @pause.active?(@now + 60)
    refute File.exist?(@path)
    assert_nil @pause.until_time
  end

  def test_missing_file_inactive
    refute @pause.active?(@now)
    assert_nil @pause.until_time
  end

  def test_corrupt_or_empty_file_inactive_and_removed
    ['', 'not json', '{"until": "soon"}', '[]', 'null', '{"by": "x"}'].each do |body|
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, body)
      assert_nil @pause.until_time, body
      refute @pause.active?(@now), body
      refute File.exist?(@path), body
    end
  end

  def test_for_paths
    assert_equal File.join(@dir, 'paused'), ReviewRun::Pause.for(@dir, 'claude').path
    assert_equal File.join(@dir, 'paused-codex'), ReviewRun::Pause.for(@dir, 'codex').path
  end

  def test_long_threshold
    p = ReviewRun::Pause.for(@dir, 'codex')
    p.set(@now + 12 * 3600, by: 'w')
    refute p.long?(@now)
    assert_equal :short, p.state(@now)
    p.set(@now + 12 * 3600 + 1, by: 'w')
    assert p.long?(@now)
    assert_equal :long, p.state(@now)
  end

  def test_state_none_when_missing_or_expired
    p = ReviewRun::Pause.for(@dir, 'claude')
    assert_equal :none, p.state(@now)
    p.set(@now - 1, by: 'w')
    assert_equal :none, p.state(@now)
    refute File.exist?(p.path)
  end

  def test_state_corrupt_file_none_and_removed
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, 'not json')
    assert_equal :none, @pause.state(@now)
    refute @pause.long?(@now)
    refute File.exist?(@path)
  end

  def test_clear
    @pause.set(@now + 60, by: 'p-t1')
    @pause.clear
    refute File.exist?(@path)
    @pause.clear
    refute @pause.active?(@now)
  end
end
