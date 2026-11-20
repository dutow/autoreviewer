require 'minitest/autorun'
require 'json'
require 'tmpdir'

require_relative '../../lib/review_run/stream'
require_relative '../../lib/review_run/usage'

class UsageTest < Minitest::Test
  T0 = Time.utc(2026, 11, 20, 10, 0, 0)

  def result(cost, dur, tokens)
    ReviewRun::Result.from_event(
      'type' => 'result', 'total_cost_usd' => cost, 'duration_ms' => dur,
      'num_turns' => 3, 'session_id' => 'sess-1',
      'modelUsage' => { 'claude-opus-x' => {
        'inputTokens' => tokens, 'outputTokens' => 2 * tokens,
        'cacheReadInputTokens' => 3 * tokens, 'cacheCreationInputTokens' => 4 * tokens,
        'costUSD' => cost
      } }
    )
  end

  def with_path
    Dir.mktmpdir { |d| yield File.join(d, 'usage.json') }
  end

  def load_json(path)
    JSON.parse(File.read(path))
  end

  def test_totals_sum_phases
    with_path do |path|
      u = ReviewRun::Usage.new(path: path, route: 'single', claude_version: '2.1.0')
      u.add(phase: 'review', model: 'opus', result: result(1.5, 1000, 10), started_at: T0)
      u.add(phase: 'draft', model: 'sonnet', result: result(0.5, 500, 5), started_at: T0 + 60)
      u.write
      d = load_json(path)
      assert_equal 1, d['schema']
      assert_equal 'single', d['route']
      assert_equal 2, d['phases'].size
      assert_equal 'ok', d['phases'][0]['status']
      assert_equal '2026-11-20T10:00:00Z', d['phases'][0]['started_at']
      assert_equal 2.0, d['total']['cost_usd']
      assert_equal 1500, d['total']['duration_ms']
      assert_equal({ 'input' => 15, 'output' => 30, 'cache_read' => 45, 'cache_write' => 60 },
                   d['total']['tokens'])
      assert_equal 10, d['phases'][0]['models']['claude-opus-x']['input']
      assert File.read(path).end_with?("}\n")
    end
  end

  def test_failed_phase_recorded_with_reason
    with_path do |path|
      u = ReviewRun::Usage.new(path: path, route: 'single', claude_version: '2.1.0')
      u.fail(phase: 'review', reason: 'died', started_at: T0)
      u.fail(phase: 'draft', reason: 'limit', result: result(0.25, 100, 1), started_at: T0)
      u.write
      a, b = load_json(path)['phases']
      assert_equal 'failed', a['status']
      assert_equal 'died', a['reason']
      assert_nil a['session_id']
      assert_equal 0, a['cost_usd']
      assert_equal 0, a['tokens']['input']
      assert_equal({}, a['models'])
      assert_equal 'sess-1', b['session_id']
      assert_equal 0.25, b['cost_usd']
      assert_equal 0.25, load_json(path)['total']['cost_usd']
    end
  end

  def test_resume_appends_to_existing_file
    with_path do |path|
      u = ReviewRun::Usage.new(path: path, route: 'single', claude_version: '1')
      u.add(phase: 'review', model: 'opus', result: result(1.0, 100, 1), started_at: T0)
      u.write
      u2 = ReviewRun::Usage.new(path: path, route: 'split', claude_version: '2')
      u2.add(phase: 'draft', model: 'opus', result: result(2.0, 200, 2), started_at: T0)
      u2.write
      d = load_json(path)
      assert_equal %w[review draft], d['phases'].map { |p| p['phase'] }
      assert_equal 'split', d['route']
      assert_equal '2', d['claude_version']
      assert_equal 3.0, d['total']['cost_usd']
      assert_equal 300, d['total']['duration_ms']
    end
  end

  def test_append_log_writes_jsonl
    Dir.mktmpdir do |d|
      log = File.join(d, 'sub', 'usage.log')
      ReviewRun::Usage.append_log(log, 'phase' => 'a', 'cost_usd' => 1)
      ReviewRun::Usage.append_log(log, 'phase' => 'b', 'cost_usd' => 2)
      lines = File.readlines(log).map { |l| JSON.parse(l) }
      assert_equal %w[a b], lines.map { |l| l['phase'] }
    end
  end
end
