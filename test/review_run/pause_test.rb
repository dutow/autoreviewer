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

  def test_clear
    @pause.set(@now + 60, by: 'p-t1')
    @pause.clear
    refute File.exist?(@path)
    @pause.clear
    refute @pause.active?(@now)
  end
end
