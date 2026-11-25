require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'time'

require_relative 'replay_fixture'

class ReplayCliTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CLI = File.join(ROOT, 'bin', 'review-replay')
  FAKE = File.join(ROOT, 'test', 'fixtures', 'review_run', 'fake-claude')
  FAKE_CODEX = File.join(ROOT, 'test', 'fixtures', 'review_run', 'fake-codex')

  def setup
    @root = File.realpath(Dir.mktmpdir)
    @live = ReplayFixture.live_workspace(@root)
    @calls_file = File.join(@root, 'calls.jsonl')
    plan('a' => { 'write' => ['a.md'] }, 'b' => { 'write' => ['05-summary.md'] })
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def plan(h)
    @plan = File.join(@root, 'plan.json')
    File.write(@plan, JSON.generate(h))
  end

  def env
    { 'WORKSPACE_DIR' => @live, 'REPLAY_DIR' => File.join(@root, 'replay'), 'STATE_DIR' => File.join(@root, 'state'),
      'CLAUDE_BIN' => FAKE, 'CODEX_BIN' => FAKE_CODEX, 'FAKE_CLAUDE_PLAN' => @plan, 'FAKE_CLAUDE_CALLS' => @calls_file,
      'TMUX' => nil, 'ANTHROPIC_API_KEY' => nil, 'REVIEW_DONE_FILE' => nil }
  end

  def replay(*args)
    args = %w[p t1 v2 full] if args.empty?
    Open3.capture2e(env, CLI, *args, chdir: @root)
  end

  def run_dir(*parts)
    File.join(@root, 'replay', 'p', 't1', 'v2-full-1', *parts)
  end

  def calls
    File.exist?(@calls_file) ? File.readlines(@calls_file).map { |l| JSON.parse(l) } : []
  end

  def git(dir, *args)
    ReplayFixture.git(dir, *args)
  end

  def worktrees
    git(File.join(@live, 'p', 'master'), 'worktree', 'list', '--porcelain').scan(/^worktree (.+)$/).flatten
  end

  def replay_json
    JSON.parse(File.read(run_dir('replay.json')))
  end

  def test_replay_runs_route_in_clone
    out, st = replay
    assert st.success?, out
    assert_equal %w[a b], calls.map { |c| c['phase'] }
    calls.each { |c| assert_equal run_dir('ws'), File.realpath(c['cwd']) }
    assert File.file?(run_dir('findings', 'a.md')), out
    assert File.file?(run_dir('findings', '05-summary.md')), out
  end

  def test_replay_note_passed
    out, st = replay
    assert st.success?, out
    assert_equal [true, true], calls.map { |c| c['replay_note'] }
  end

  def test_state_kept_in_run_dir
    out, st = replay
    assert st.success?, out
    assert File.file?(run_dir('state', 'usage.log')), out
    refute File.exist?(File.join(@root, 'state', 'usage.log'))
  end

  def test_live_workspace_untouched
    head = git(@live, 'rev-parse', 'HEAD')
    status = git(@live, 'status', '--porcelain', '--ignored')
    before = Dir.glob(File.join(@live, 'p', 'findings', 't1', 'v2', '*')).to_h { |f| [f, File.read(f)] }
    out, st = replay
    assert st.success?, out
    assert_equal head, git(@live, 'rev-parse', 'HEAD')
    assert_equal status, git(@live, 'status', '--porcelain', '--ignored')
    assert_equal before, Dir.glob(File.join(@live, 'p', 'findings', 't1', 'v2', '*')).to_h { |f| [f, File.read(f)] }
    assert_equal ['main'], git(@live, 'branch', '--format=%(refname:short)').split
  end

  def test_replay_json_finished
    out, st = replay
    assert st.success?, out
    data = replay_json
    assert_equal true, data['ok']
    assert Time.iso8601(data['finished_at'])
    assert_equal false, data['inputs_changed']
    assert_in_delta 1.0, data['cost_usd']
  end

  def test_failed_phase_cleans_worktree
    plan('a' => { 'write' => ['a.md'] }, 'b' => { 'exit' => 1 })
    out, st = replay
    refute st.success?, out
    assert_equal false, replay_json['ok']
    refute_includes worktrees, run_dir('ws', 'p', 'review', 't1')
    refute Dir.exist?(run_dir('ws', 'p', 'review', 't1'))
  end

  def test_agent_passed_through
    out, st = replay('--agent', 'codex', 'p', 't1', 'v2', 'full')
    assert st.success?, out
    assert_equal %w[codex codex], calls.map { |c| c['agent'] }
    assert_equal 'codex', replay_json['agent']
  end

  def test_agent_nil_when_not_forced
    out, st = replay
    assert st.success?, out
    assert_nil replay_json['agent']
  end

  def test_unknown_agent_is_usage_error
    out, st = replay('--agent', 'gemini', 'p', 't1', 'v2', 'full')
    assert_equal 1, st.exitstatus, out
    refute Dir.exist?(File.join(@root, 'replay'))
  end

  def test_keep_worktree
    out, st = replay('--keep-worktree', 'p', 't1', 'v2', 'full')
    assert st.success?, out
    assert_includes worktrees, run_dir('ws', 'p', 'review', 't1')
  end

  def test_removes_worktree_by_default
    out, st = replay
    assert st.success?, out
    assert_equal [File.join(@live, 'p', 'master'), File.join(@live, 'p', 'review', 't1')].sort, worktrees.sort
  end

  def test_prints_compare_hint
    out, st = replay
    assert st.success?, out
    assert_equal ["replay: #{run_dir}\n", "compare: bin/review-compare #{run_dir} #{@live}/p/findings/t1/v2\n"],
                 out.lines.last(2)
  end

  def test_version_mismatch_exits_before_creating_run
    File.write(File.join(@live, 'p', 'review', 't1', 'metadata.json'), JSON.generate('version' => 3))
    out, st = replay
    refute st.success?
    assert_includes out, 'ERROR: p/review/t1 is at v3, not v2'
    refute Dir.exist?(File.join(@root, 'replay'))
    assert_empty calls
  end

  def test_usage_error
    out, st = replay('p', 't1')
    refute st.success?
    assert_includes out, 'usage: review-replay'
  end
end
