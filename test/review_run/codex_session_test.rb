require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'stringio'

require_relative '../../lib/review_run/codex_session'

class CodexSessionTest < Minitest::Test
  FAKE = File.expand_path('../fixtures/review_run/fake-codex', __dir__)
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
    ReviewRun::CodexSession.new(codex_bin: bin, workspace_dir: @dir, out: @out)
  end

  def run_a(model: 'gpt-6.2-astra', effort: 'xhigh')
    session.run(PROMPT, model: model, effort: effort, log: @log)
  end

  def calls
    File.readlines(@calls_file).map { |l| JSON.parse(l) }
  end

  def test_run_returns_result_and_logs_raw
    plan('a' => { 'text' => 'all good' })
    result, status, rate_limit = run_a
    assert status.success?
    assert_nil rate_limit
    refute result.is_error
    assert_equal 'all good', result.text
    assert_equal 2, result.num_turns
    assert_equal 20, result.tokens['output']
    assert_equal 10, result.tokens['input']
    assert_equal ['gpt-6.2-astra'], result.models.keys
    assert_operator result.duration_ms, :>=, 0

    raw = File.readlines(@log)
    assert(raw.any? { |l| l.include?('"type":"turn.completed"') })
    assert_includes @out.string, '== thread fake-a'
    assert_includes @out.string, '-> shell: /usr/bin/zsh'
    assert_includes @out.string, '== result: ok, 60 tokens'
    refute_includes @out.string, '"type"'
  end

  def test_argv_cwd_and_child_env
    run_a
    c = calls.first
    assert_equal 'codex', c['agent']
    assert_equal ['exec', '--json', '--dangerously-bypass-approvals-and-sandbox', '-C', @dir,
                  '-m', 'gpt-6.2-astra', '-c', 'model_reasoning_effort=xhigh', '-'], c['argv']
    assert_equal File.realpath(@dir), File.realpath(c['cwd'])
    assert_equal false, c['done_file_env']
    assert_equal({ 'REVIEW_RUN' => '1', 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS' => '1' }, c['env'])
  end

  def test_no_effort_flag_when_nil
    run_a(effort: nil)
    assert_equal ['-m', 'gpt-6.2-astra', '-'], calls.first['argv'].last(3)
    refute_includes calls.first['argv'], '-c'
  end

  def test_limit_result
    plan('a' => { 'limit_times' => 1 })
    result, status, rate_limit = run_a
    assert result.limit_hit?
    assert_equal 1, status.exitstatus
    assert_nil rate_limit
    assert_includes @out.string, '== result: failed: You\'ve hit your usage limit'
  end

  def test_fail_text
    plan('a' => { 'fail_text' => 'boom' })
    result, status = run_a
    assert result.is_error
    refute result.limit_hit?
    assert_equal 'boom', result.text
    assert_equal 1, status.exitstatus
  end

  def test_log_appends
    2.times { run_a }
    assert_equal 2, File.readlines(@log).count { |l| l.include?('"type":"turn.completed"') }
  end

  def test_missing_binary_raises
    assert_raises(SystemCallError) do
      session(File.join(@dir, 'nope')).run(PROMPT, model: 'm', effort: nil, log: @log)
    end
  end

  def test_version
    assert_equal '9.9.9', session.version
    assert_equal 'unknown', session(File.join(@dir, 'nope')).version
  end
end
