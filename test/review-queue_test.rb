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
    @state = File.join(@dir, 'state')
    @ws = File.join(@dir, 'ws')
    ENV['STATE_DIR'] = @state
    ENV['WORKSPACE_DIR'] = @ws
    @claude = ReviewRun::Pause.for(@state, 'claude')
    @codex = ReviewRun::Pause.for(@state, 'codex')
    @queue = ReviewQueue.new
    @now = Time.at(1_800_000_000)
    @short = @now + 600
    @long = @now + 13 * 3600
  end

  def teardown
    FileUtils.rm_rf(@dir)
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def project(name, review)
    FileUtils.mkdir_p(File.join(@ws, name))
    File.write(File.join(@ws, name, 'project.yaml'), "review:\n#{review}")
  end

  def held(line, at = @now)
    out, = capture_io { @result = @queue.held?(line, at) }
    [@result, out]
  end

  def hold_line(line, agent, t)
    /\A\[\d\d:\d\d:\d\d\] holding #{Regexp.escape(line)}: #{agent} paused until #{Regexp.escape(t.strftime('%Y-%m-%d %H:%M:%S'))} \(usage limit\)\n\z/
  end

  def test_not_held_without_pause
    project('p', "  command: rev\n")
    res, out = held('p t1')
    refute res
    assert_empty out
  end

  def test_claude_project_held_by_claude_pause_only
    project('p', "  command: rev\n")
    @codex.set(@short, by: 'x')
    refute held('p t1').first
    @claude.set(@short, by: 'x')
    res, out = held('p t1')
    assert res
    assert_match hold_line('p t1', 'claude', @short), out
  end

  def test_codex_project_held_by_codex_pause_only
    project('p', "  agent: codex\n")
    @claude.set(@short, by: 'x')
    refute held('p t1').first
    @codex.set(@short, by: 'x')
    res, out = held('p t1')
    assert res
    assert_match hold_line('p t1', 'codex', @short), out
  end

  def test_alternate_held_only_when_both_paused
    project('p', "  agent: alternate\n")
    @claude.set(@short, by: 'x')
    refute held('p t1').first
    @codex.set(@long, by: 'x')
    assert held('p t1').first
  end

  def test_both_held_by_short_not_by_single_long
    project('p', "  agent: both\n  route: single\n")
    @codex.set(@long, by: 'x')
    refute held('p t1').first
    @codex.set(@short, by: 'x')
    assert held('p t1').first
  end

  def test_both_held_by_two_long
    project('p', "  agent: both\n  route: single\n")
    @claude.set(@long, by: 'x')
    @codex.set(@long, by: 'x')
    assert held('p t1').first
  end

  def test_commit_batch_held_by_claude_pause
    project('p', "  agent: codex\n")
    @codex.set(@short, by: 'x')
    refute held('p commits a..b').first
    @claude.set(@short, by: 'x')
    assert held('p commits a..b').first
  end

  def test_prints_once_per_pause
    project('p', "  command: rev\n")
    @claude.set(@short, by: 'x')
    out, = capture_io do
      assert @queue.held?('p t1', @now)
      assert @queue.held?('p t1', @now + 30)
    end
    assert_match hold_line('p t1', 'claude', @short), out

    @claude.set(@now + 1200, by: 'y')
    out, = capture_io { assert @queue.held?('p t1', @now + 90) }
    assert_match hold_line('p t1', 'claude', @now + 1200), out
  end

  def test_expired_pause_removed_and_reprinted_for_next
    project('p', "  command: rev\n")
    @claude.set(@short, by: 'x')
    capture_io { assert @queue.held?('p t1', @now) }
    out, = capture_io { refute @queue.held?('p t1', @short) }
    assert_empty out
    refute File.exist?(@claude.path)

    @claude.set(@short, by: 'x')
    out, = capture_io { assert @queue.held?('p t1', @now + 10) }
    assert_match hold_line('p t1', 'claude', @short), out
  end

  def test_corrupt_pause_file_ignored
    project('p', "  command: rev\n")
    FileUtils.mkdir_p(@state)
    File.write(@claude.path, '{')
    res, out = held('p t1')
    refute res
    assert_empty out
    refute File.exist?(@claude.path)
  end

  def test_unknown_project_not_held
    @claude.set(@short, by: 'x')
    res, out = held('nope t1')
    refute res
    assert_empty out
  end

  def test_bad_config_not_held
    project('p', "  agent: bogus\n")
    @claude.set(@short, by: 'x')
    @codex.set(@short, by: 'x')
    refute held('p t1').first
  end
end

class ReviewQueuePreflightTest < Minitest::Test
  ENV_KEYS = %w[STATE_DIR WORKSPACE_DIR CODEX_HOME OPENAI_API_KEY CODEX_API_KEY PATH].freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    ENV_KEYS.each { |k| ENV.delete(k) unless k == 'PATH' }
    @dir = Dir.mktmpdir
    @ws = File.join(@dir, 'ws')
    ENV['STATE_DIR'] = File.join(@dir, 'state')
    ENV['WORKSPACE_DIR'] = @ws
    ENV['CODEX_HOME'] = File.join(@dir, 'codex-home')
    FileUtils.mkdir_p(File.join(@ws, '.git'))
    @queue = ReviewQueue.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def project(name, yaml)
    FileUtils.mkdir_p(File.join(@ws, name))
    File.write(File.join(@ws, name, 'project.yaml'), yaml)
  end

  def run_preflight
    out, = capture_io { @result = @queue.send(:preflight) }
    out
  end

  def test_codex_project_without_auth_fails
    project('p', "review:\n  agent: codex\n")
    out = run_preflight
    refute @result
    assert_includes out, "FAIL codex authenticated: codex CLI missing or not logged in - run 'task codex-login'"
  end

  def with_fake_codex
    bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, 'codex'), "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, File.join(bin, 'codex'))
    ENV['PATH'] = "#{bin}:#{ENV['PATH']}"
  end

  def test_codex_auth_file_passes
    project('p', "review:\n  agent: codex\n")
    with_fake_codex
    FileUtils.mkdir_p(ENV['CODEX_HOME'])
    File.write(File.join(ENV['CODEX_HOME'], 'auth.json'), '{}')
    assert_match(/^OK   codex authenticated$/, run_preflight)
  end

  %w[OPENAI_API_KEY CODEX_API_KEY].each do |key|
    define_method("test_codex_#{key.downcase}_passes") do
      project('p', "review:\n  agent: codex\n")
      with_fake_codex
      ENV[key] = 'k'
      assert_match(/^OK   codex authenticated$/, run_preflight)
    end
  end

  def test_codex_installed_without_auth_fails
    project('p', "review:\n  agent: codex\n")
    with_fake_codex
    assert_match(/^FAIL codex authenticated: /, run_preflight)
  end

  def test_all_claude_has_no_codex_check
    project('p', "review:\n  command: rev\n")
    project('_template', "review:\n  agent: codex\n")
    refute_includes run_preflight, 'codex authenticated'
  end
end

class ReviewQueueLaunchTest < Minitest::Test
  ENV_KEYS = %w[STATE_DIR WORKSPACE_DIR REVIEW_QUEUE_FILE REVIEW_QUEUE_PROCESSED].freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    ENV_KEYS.each { |k| ENV.delete(k) }
    @dir = Dir.mktmpdir
    @ws = File.join(@dir, 'my ws')
    @state = File.join(@dir, 'state')
    ENV['STATE_DIR'] = @state
    ENV['WORKSPACE_DIR'] = @ws
    @queue = ReviewQueue.new
    @base = File.expand_path('..', __dir__)
    @calls = []
    @watchers = []
    calls = @calls
    watchers = @watchers
    @queue.define_singleton_method(:tmux_new_window) { |*a| calls << a; "@#{calls.size + 6}" }
    @queue.define_singleton_method(:spawn_watcher) { |*a| watchers << a }
  end

  def teardown
    FileUtils.rm_rf(@dir)
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def project(yaml)
    FileUtils.mkdir_p(File.join(@ws, 'p'))
    File.write(File.join(@ws, 'p', 'project.yaml'), yaml)
  end

  def test_runner_cmd_topic
    sig = File.join(@state, 'signals', 'a b.done')
    cmd = @queue.send(:runner_cmd, 'p', 't1', sig)
    assert_equal "cd #{Shellwords.escape(@ws)} && #{Shellwords.escape(File.join(@base, 'bin', 'review-run'))} " \
                 "--done-file #{Shellwords.escape(sig)} p t1", cmd
    refute_includes cmd, 'REVIEW_DONE_FILE'
    refute_match(/ claude /, cmd)
  end

  def test_runner_cmd_commits
    cmd = @queue.send(:runner_cmd, 'p', 'abc..def', '/s/x.done', commits: true)
    assert_match(%r{review-run --done-file /s/x\.done --commits p abc\.\.def\z}, cmd)
  end

  def test_launch_uses_runner_with_phases
    project("review:\n  command: rev\n  phases: [a]\n")
    out, = capture_io { @queue.send(:launch_review, 'p', 'rev', 't1') }
    cmd = @calls.first.last
    assert_includes cmd, 'bin/review-run --done-file'
    refute_match(/ claude /, cmd)
    refute_match(/WARNING/, out)
  end

  def test_fallback_without_phases
    project("review:\n  command: rev\n")
    out, = capture_io { @queue.send(:launch_review, 'p', 'rev', 't1') }
    sig, name, id = @watchers.first
    assert_equal ['p-t1', '@7'], [name, id]
    assert_equal "cd #{Shellwords.escape(@ws)} && REVIEW_DONE_FILE=#{Shellwords.escape(sig)} " \
                 'claude --model opus --dangerously-skip-permissions --disallowedTools AskUserQuestion ' \
                 "-n p-t1 -- #{Shellwords.escape('/rev t1')}",
                 @calls.first.last
    assert_equal 'p-t1', @calls.first.first
    assert_match(/WARNING.*review\.phases/, out)
  end

  def test_commits_always_runner
    project("review:\n  command: rev\n")
    capture_io { @queue.send(:launch_review, 'p', 'x', 'a..b', window_name: 'p-commits-a-b', commits: true) }
    assert_includes @calls.first.last, '--commits p a..b'
  end

  def test_relaunch_same_topic_gets_own_signal_and_window_id
    project("review:\n  command: rev\n  phases: [a]\n")
    capture_io { 2.times { @queue.send(:launch_review, 'p', 'rev', 't1') } }
    assert_equal %w[p-t1 p-t1], @calls.map(&:first)
    (s1, n1, id1), (s2, n2, id2) = @watchers
    assert_equal %w[p-t1 p-t1], [n1, n2]
    assert_equal %w[@7 @8], [id1, id2]
    refute_equal s1, s2
    [s1, s2].each do |s|
      assert_equal File.join(@state, 'signals'), File.dirname(s)
      assert_match(/\Ap-t1-\d+-\d+-\d+\.done\z/, File.basename(s))
    end
    assert_includes @calls[0].last, "--done-file #{Shellwords.escape(s1)} "
    assert_includes @calls[1].last, "--done-file #{Shellwords.escape(s2)} "
  end

  def test_no_watcher_when_window_fails
    project("review:\n  command: rev\n  phases: [a]\n")
    @queue.define_singleton_method(:tmux_new_window) { |*| nil }
    out, = capture_io { @queue.send(:launch_review, 'p', 'rev', 't1') }
    assert_empty @watchers
    assert_match(/WARNING: could not open tmux window 'p-t1'/, out)
  end

  def fake_bin(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'tmux'), "#!/bin/sh\necho \"$*\" >> \"$FAKE_TMUX_LOG\"\necho '@42'\n")
    File.write(File.join(dir, 'sleep'), "#!/bin/sh\nexit 0\n")
    %w[tmux sleep].each { |f| File.chmod(0o755, File.join(dir, f)) }
    dir
  end

  def with_fake_tmux
    bin = fake_bin(File.join(@dir, 'bin'))
    log = File.join(@dir, 'tmux.log')
    saved = ENV.to_h.slice('PATH', 'FAKE_TMUX_LOG')
    ENV['PATH'] = "#{bin}:#{ENV['PATH']}"
    ENV['FAKE_TMUX_LOG'] = log
    yield log
  ensure
    saved.each { |k, v| ENV[k] = v }
    ENV.delete('FAKE_TMUX_LOG') unless saved.key?('FAKE_TMUX_LOG')
  end

  def test_tmux_new_window_returns_id
    q = ReviewQueue.new
    with_fake_tmux do |log|
      assert_equal '@42', q.send(:tmux_new_window, 'p-t1', 'echo hi')
      assert_equal "new-window -P -F \#{window_id} -n p-t1 -d echo hi\n", File.read(log)
    end
  end

  def test_watcher_kills_window_by_id
    q = ReviewQueue.new
    sig = File.join(@state, 'signals', 'p-t1-1-2-3.done')
    script = q.send(:watcher_script, sig, 'p-t1', '@42')
    assert_includes script, 'tmux kill-window -t @42'
    refute_includes script, 'reviews:'
    refute_includes script, 'kill-window -t p-t1'
    FileUtils.mkdir_p(File.dirname(sig))
    FileUtils.touch(sig)
    with_fake_tmux do |log|
      _out, st = Open3.capture2e('bash', '-c', script)
      assert st.success?
      assert_equal "kill-window -t @42\n", File.read(log)
    end
    refute File.exist?(sig)
  end
end
