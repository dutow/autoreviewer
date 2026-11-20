require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'stringio'

require_relative '../../lib/review_run/session'

class SessionTest < Minitest::Test
  FAKE = File.expand_path('../fixtures/review_run/fake-claude', __dir__)
  ENV_KEYS = %w[FAKE_CLAUDE_PLAN FAKE_CLAUDE_CALLS REVIEW_DONE_FILE].freeze
  PROMPT = "Phase: a\nOutput directory: out\n\nDo a\n".freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    @dir = Dir.mktmpdir
    @calls_file = File.join(@dir, 'calls.jsonl')
    @log = File.join(@dir, 'logs', 'p-t1', '01-a.jsonl')
    ENV['FAKE_CLAUDE_CALLS'] = @calls_file
    ENV['REVIEW_DONE_FILE'] = File.join(@dir, 'done')
    plan('a' => {})
    @out = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def plan(h)
    path = File.join(@dir, 'plan.json')
    File.write(path, JSON.generate(h))
    ENV['FAKE_CLAUDE_PLAN'] = path
  end

  def session(bin = FAKE)
    ReviewRun::Session.new(claude_bin: bin, workspace_dir: @dir, out: @out)
  end

  def run_a(model: 'opus', effort: nil)
    session.run(PROMPT, model: model, effort: effort, log: @log)
  end

  def calls
    File.readlines(@calls_file).map { |l| JSON.parse(l) }
  end

  def test_run_returns_result_and_logs_raw
    plan('a' => { 'noise' => true, 'text' => 'all good' })
    result, status = run_a
    assert status.success?
    refute result.is_error
    assert_equal 'all good', result.text
    assert_equal 2, result.num_turns
    assert_equal 20, result.tokens['output']

    raw = File.readlines(@log)
    assert_includes raw, "fake-claude: stderr noise\n"
    assert(raw.any? { |l| l.include?('"type":"result"') })
    assert_includes @out.string, '== session fake-a (fake-model)'
    assert_includes @out.string, "fake-claude: stderr noise\n"
    assert_includes @out.string, '== result: success'
    refute_includes @out.string, '"type"'
  end

  def test_argv_cwd_and_child_env
    run_a(model: 'sonnet', effort: 'high')
    c = calls.first
    assert_equal %w[-p --model sonnet --effort high --dangerously-skip-permissions
                    --disallowedTools AskUserQuestion --output-format stream-json --verbose], c['argv']
    assert_equal File.realpath(@dir), File.realpath(c['cwd'])
    assert_equal false, c['done_file_env']
    assert_equal({ 'REVIEW_RUN' => '1', 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS' => '1' }, c['env'])
  end

  def test_no_model_or_effort_flags_when_nil
    run_a(model: nil)
    refute_includes calls.first['argv'], '--model'
    refute_includes calls.first['argv'], '--effort'
  end

  def test_limit_result
    plan('a' => { 'limit_first' => true })
    result, status, rate_limit = run_a
    assert result.limit_hit?
    assert_equal 1, status.exitstatus
    assert_nil rate_limit
  end

  def test_rejected_rate_limit_event_returned
    plan('a' => { 'limit_first' => true, 'limit_text' => 'API Error: 429',
                  'limit_event' => { 'status' => 'rejected', 'resetsAt' => 1_800_000_000, 'rateLimitType' => 'five_hour' } })
    result, _status, rate_limit = run_a
    refute result.limit_hit?
    assert rate_limit.rejected?
    assert_equal Time.at(1_800_000_000), rate_limit.resets_at
    assert_match(/== rate limit rejected \(five_hour\), resets /, @out.string)
    assert(File.readlines(@log).any? { |l| l.include?('"type":"rate_limit_event"') })
  end

  def test_allowed_rate_limit_event_ignored
    plan('a' => { 'rate_limit' => { 'status' => 'allowed_warning', 'resetsAt' => 1_800_000_000 } })
    _result, status, rate_limit = run_a
    assert status.success?
    assert_nil rate_limit
  end

  def test_no_result_event
    plan('a' => { 'no_result' => true })
    result, status = run_a
    assert_nil result
    assert status.success?
  end

  def test_log_appends
    2.times { run_a }
    assert_equal 2, File.readlines(@log).count { |l| l.include?('"type":"result"') }
  end

  def test_missing_binary_raises
    assert_raises(SystemCallError) do
      session(File.join(@dir, 'nope')).run(PROMPT, model: nil, effort: nil, log: @log)
    end
  end

  def test_version
    assert_equal '9.9.9', session.version
    assert_equal 'unknown', session(File.join(@dir, 'nope')).version
  end
end
