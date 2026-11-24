require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'stringio'

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

  def test_last_status_is_latest_record_of_phase
    with_path do |path|
      u = ReviewRun::Usage.new(path: path, route: 'single', claude_version: '1')
      u.add(phase: 'a', model: 'opus', result: result(1.0, 100, 1), started_at: T0)
      u.fail(phase: 'b', reason: 'x', started_at: T0)
      u.write
      u2 = ReviewRun::Usage.new(path: path, route: 'single', claude_version: '1')
      assert_equal 'ok', u2.last_status('a')
      assert_equal 'failed', u2.last_status('b')
      assert_nil u2.last_status('c')
      u2.add(phase: 'b', model: 'opus', result: result(1.0, 100, 1), started_at: T0)
      assert_equal 'ok', u2.last_status('b')
    end
  end

  def test_limit_entry_counts_in_totals
    with_path do |path|
      u = ReviewRun::Usage.new(path: path, route: 'single', claude_version: '1')
      refute u.changed?
      u.limit(phase: 'a', model: 'opus', result: result(0.25, 100, 1), started_at: T0)
      assert u.changed?
      u.add(phase: 'a', model: 'opus', result: result(1.0, 200, 2), started_at: T0)
      u.write
      d = load_json(path)
      assert_equal [%w[a limit opus], %w[a ok opus]], d['phases'].map { |p| p.values_at('phase', 'status', 'model') }
      assert_equal 1.25, d['total']['cost_usd']
      assert_equal 3, d['total']['tokens']['input']
      assert_equal 'ok', ReviewRun::Usage.new(path: path, route: 'single', claude_version: '1').last_status('a')
    end
  end

  def test_write_is_atomic
    with_path do |path|
      u = ReviewRun::Usage.new(path: path, route: 'single', claude_version: '1')
      u.add(phase: 'a', model: 'opus', result: result(1.0, 100, 1), started_at: T0)
      u.write
      assert_equal ['usage.json'], Dir.children(File.dirname(path))
    end
  end

  def test_corrupt_file_warns_and_starts_fresh
    ['{"phases": [', '[1, 2]', '{"phases": "x"}', 'null'].each do |bad|
      with_path do |path|
        File.write(path, bad)
        out = StringIO.new
        u = ReviewRun::Usage.new(path: path, route: 'single', claude_version: '1', out: out)
        assert_match(/\AWARNING: .*usage\.json unreadable .*starting fresh\n\z/, out.string, bad)
        u.add(phase: 'a', model: 'opus', result: result(1.0, 100, 1), started_at: T0)
        u.write
        assert_equal %w[a], load_json(path)['phases'].map { |p| p['phase'] }
      end
    end
  end

  CodexResult = Struct.new(:duration_ms, :num_turns, :cost_usd, :session_id, :tokens, :models)

  def codex_result
    CodexResult.new(500, 2, nil, 'thr-1',
                    { 'input' => 7, 'output' => 3, 'cache_read' => 1, 'cache_write' => 0 },
                    { 'gpt-x' => { 'input' => 7, 'cost_usd' => nil } })
  end

  def new_usage(path, **kw)
    ReviewRun::Usage.new(path: path, route: 'single', claude_version: '1', **kw)
  end

  def test_entry_records_agent
    with_path do |path|
      u = new_usage(path)
      u.add(phase: 'a', model: 'opus', result: result(1.0, 100, 1), started_at: T0)
      u.add(phase: 'b', model: 'gpt-x', result: codex_result, started_at: T0, agent: 'codex')
      u.write
      a, b = load_json(path)['phases']
      assert_equal 'claude', a['agent']
      assert_equal 'codex', b['agent']
      assert_nil b['cost_usd']
    end
  end

  def test_skip_entry
    with_path do |path|
      u = new_usage(path)
      u.skip(phase: 'a', agent: 'codex', reason: 'paused', started_at: T0)
      assert u.changed?
      u.write
      e = load_json(path)['phases'][0]
      assert_equal 'skipped', e['status']
      assert_equal 'codex', e['agent']
      assert_equal 'paused', e['reason']
      assert_nil e['cost_usd']
      assert_equal 0, e['tokens']['input']
      assert_nil load_json(path)['total']['cost_usd']
    end
  end

  def test_total_cost_nil_for_codex_only
    with_path do |path|
      u = new_usage(path)
      u.add(phase: 'a', model: 'gpt-x', result: codex_result, started_at: T0, agent: 'codex')
      u.write
      d = load_json(path)
      assert_nil d['total']['cost_usd']
      assert_equal 7, d['total']['tokens']['input']
    end
  end

  def test_total_cost_mixed_sums_numeric_only
    with_path do |path|
      u = new_usage(path)
      u.add(phase: 'a', model: 'opus', result: result(1.5, 100, 1), started_at: T0)
      u.add(phase: 'b', model: 'gpt-x', result: codex_result, started_at: T0, agent: 'codex')
      u.write
      assert_equal 1.5, load_json(path)['total']['cost_usd']
    end
  end

  def test_last_agent
    with_path do |path|
      u = new_usage(path)
      assert_nil u.last_agent
      u.add(phase: 'a', model: 'opus', result: result(1.0, 100, 1), started_at: T0)
      u.add(phase: 'b', model: 'gpt-x', result: codex_result, started_at: T0, agent: 'codex')
      assert_equal 'codex', u.last_agent
      assert_equal 'claude', u.last_agent('a')
      assert_equal 'codex', u.last_agent('b')
      assert_nil u.last_agent('c')
    end
  end

  def test_last_agent_old_entry_defaults_to_claude
    with_path do |path|
      File.write(path, JSON.generate('phases' => [{ 'phase' => 'a', 'status' => 'ok' }]))
      assert_equal 'claude', new_usage(path).last_agent
    end
  end

  def test_review_agent
    with_path do |path|
      assert_nil ReviewRun::Usage.review_agent(path)
      File.write(path, JSON.generate('phases' => [{ 'phase' => 'a', 'status' => 'ok' }]))
      assert_equal 'claude', ReviewRun::Usage.review_agent(path)
      File.write(path, 'garbage{')
      assert_nil ReviewRun::Usage.review_agent(path)
      File.write(path, JSON.generate('phases' => [
        { 'phase' => 'a', 'status' => 'ok', 'agent' => 'claude' },
        { 'phase' => 'b', 'status' => 'ok', 'agent' => 'codex' },
        { 'phase' => 'c', 'status' => 'failed', 'agent' => 'claude' }
      ]))
      assert_equal 'codex', ReviewRun::Usage.review_agent(path)
    end
  end

  def test_agent_metadata_survives_reload
    with_path do |path|
      u = new_usage(path, agent_mode: 'alternate')
      u.set_version('codex', '0.171.0')
      u.degraded!
      u.write
      d = load_json(path)
      assert_equal 'alternate', d['agent_mode']
      assert_equal '0.171.0', d['codex_version']
      assert_equal true, d['degraded']
      new_usage(path).write
      d = load_json(path)
      assert_equal 'alternate', d['agent_mode']
      assert_equal '0.171.0', d['codex_version']
      assert_equal true, d['degraded']
    end
  end

  def test_metadata_absent_when_unset
    with_path do |path|
      new_usage(path).write
      d = load_json(path)
      %w[agent_mode codex_version degraded discovery_base].each { |k| refute d.key?(k), k }
    end
  end

  def test_discovery_base_survives_reload
    with_path do |path|
      u = new_usage(path)
      u.discovery_base = 'abc123'
      u.write
      assert_equal 'abc123', new_usage(path).discovery_base
      u.discovery_base = nil
      u.write
      refute load_json(path).key?('discovery_base')
      assert_nil new_usage(path).discovery_base
    end
  end

  def test_discovery_dirty_kept_with_base
    with_path do |path|
      u = new_usage(path)
      u.discovery_base = 'abc123'
      u.discovery_dirty = ['p/x.txt']
      u.write
      assert_equal ['p/x.txt'], new_usage(path).discovery_dirty
      u.discovery_base = nil
      u.write
      refute load_json(path).key?('discovery_dirty')
      assert_nil new_usage(path).discovery_dirty
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
