require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'stringio'
require 'yaml'

require_relative '../../lib/review_run/runner'

class RunnerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  FAKE = File.join(ROOT, 'test', 'fixtures', 'review_run', 'fake-claude')
  CLI = File.join(ROOT, 'bin', 'review-run')
  ENV_KEYS = %w[FAKE_CLAUDE_PLAN FAKE_CLAUDE_CALLS REVIEW_DONE_FILE ANTHROPIC_API_KEY TMUX].freeze
  API_WARNING = 'WARNING: ANTHROPIC_API_KEY is set; claude -p will bill the API key'.freeze
  OUT_REL = 'p/findings/t1/v2'.freeze

  PHASES = [
    { 'name' => 'a', 'prompt' => '01-a.md', 'output' => 'a.md' },
    { 'name' => 'b', 'prompt' => '02-b.md', 'output' => 'b.md', 'model' => 'sonnet', 'effort' => 'high' },
    { 'name' => 'c', 'prompt' => '03-c.md', 'output' => 'c.md' }
  ].freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    ENV_KEYS.each { |k| ENV.delete(k) }
    @root = Dir.mktmpdir
    @base = File.join(@root, 'base')
    @ws = File.join(@root, 'ws')
    @state = File.join(@root, 'state')
    @calls_file = File.join(@root, 'calls.jsonl')
    ENV['FAKE_CLAUDE_CALLS'] = @calls_file
    @slept = []
    build_base
    build_workspace
    plan(default_plan)
  end

  def teardown
    FileUtils.rm_rf(@root)
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def build_base
    FileUtils.mkdir_p(File.join(@base, 'bin'))
    stub = File.join(@base, 'bin', 'findings-metadata')
    File.write(stub, <<~RB)
      #!/usr/bin/env ruby
      require 'json'
      dir = File.join(File.dirname(ARGV[1]), 'findings', ARGV[2], 'v2')
      File.write(File.join(dir, 'metadata.json'), JSON.generate('stub' => true) + "\\n")
    RB
    File.chmod(0o755, stub)
  end

  def build_workspace
    FileUtils.mkdir_p([File.join(@ws, 'p', 'review', 't1'), @state])
    File.write(File.join(@ws, 'p', 'project.yaml'), "name: p\nreview:\n  phases: p\n")
    File.write(File.join(@ws, 'p', 'review', 't1', 'metadata.json'), JSON.generate('version' => 2))
    File.write(File.join(@ws, '.gitignore'), "p/review/\np/current-reviews/\n")
    write_manifest(PHASES)
    git('init', '-q', '-b', 'main')
    git('config', 'user.email', 'test@example.com')
    git('config', 'user.name', 'test')
    git('config', 'commit.gpgsign', 'false')
    git('add', '-A')
    git('commit', '-q', '-m', 'init')
  end

  def write_manifest(phases)
    dir = File.join(@ws, '.claude', 'review-phases', 'p')
    FileUtils.mkdir_p(dir)
    phases.each { |ph| File.write(File.join(dir, ph['prompt']), "Do #{ph['name']} for $ARGUMENTS into $OUTDIR\n") }
    File.write(File.join(dir, 'phases.yaml'), YAML.dump('default_model' => 'opus', 'routes' => { 'full' => phases }))
  end

  def default_plan
    %w[a b c].to_h { |n| [n, { 'write' => ["#{n}.md"] }] }
  end

  def plan(h)
    path = File.join(@root, 'plan.json')
    File.write(path, JSON.generate(h))
    ENV['FAKE_CLAUDE_PLAN'] = path
  end

  def git(*args)
    out, st = Open3.capture2e('git', *args, chdir: @ws)
    raise "git #{args.join(' ')}: #{out}" unless st.success?
    out
  end

  def runner(sleeper: ->(s) { @slept << s }, clock: -> { Time.now })
    @out = StringIO.new
    ReviewRun::Runner.new(base_dir: @base, workspace_dir: @ws, state_dir: @state,
                          claude_bin: FAKE, out: @out, sleeper: sleeper, clock: clock)
  end

  def run_topic(**kw)
    r = runner(**kw)
    ok = nil
    capture_io { ok = r.run_topic(project: 'p', topic: 't1') }
    ok
  end

  def output
    @out.string
  end

  def calls
    File.exist?(@calls_file) ? File.readlines(@calls_file).map { |l| JSON.parse(l) } : []
  end

  def outdir(*f)
    File.join(@ws, OUT_REL, *f)
  end

  def usage
    JSON.parse(File.read(outdir('usage.json')))
  end

  def usage_log
    path = File.join(@state, 'usage.log')
    File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  def dirty(path)
    git('status', '--porcelain', '--', path)
  end

  def test_runs_all_phases_and_commits_usage
    assert run_topic, output
    assert_equal %w[a b c], calls.map { |c| c['phase'] }
    %w[a.md b.md c.md].each { |f| assert File.exist?(outdir(f)), f }

    a, b = calls
    assert_equal OUT_REL, a['outdir']
    assert_equal File.realpath(@ws), File.realpath(a['cwd'])
    %w[-p --dangerously-skip-permissions --verbose].each { |f| assert_includes a['argv'], f }
    assert_equal %w[--disallowedTools AskUserQuestion], a['argv'][a['argv'].index('--disallowedTools'), 2]
    assert_equal %w[--output-format stream-json], a['argv'][a['argv'].index('--output-format'), 2]
    assert_equal %w[--model opus], a['argv'][a['argv'].index('--model'), 2]
    refute_includes a['argv'], '--effort'
    assert_equal %w[--model sonnet --effort high], b['argv'][b['argv'].index('--model'), 4]

    u = usage
    assert_equal %w[a b c], u['phases'].map { |p| p['phase'] }
    assert_equal %w[ok ok ok], u['phases'].map { |p| p['status'] }
    assert_equal %w[opus sonnet opus], u['phases'].map { |p| p['model'] }
    assert_equal 'full', u['route']
    assert_equal '9.9.9', u['claude_version']
    assert_in_delta 1.5, u['total']['cost_usd']

    assert_equal 'review(t1): add usage', git('log', '-1', '--format=%s').strip
    assert_equal '', dirty('p/findings')
    assert_equal ["#{OUT_REL}/metadata.json", "#{OUT_REL}/usage.json"],
                 git('ls-files', "#{OUT_REL}/usage.json", "#{OUT_REL}/metadata.json").lines.map(&:strip).sort

    log = usage_log
    assert_equal 3, log.size
    assert_equal %w[time project topic version route phase model status cost_usd tokens].sort, log[0].keys.sort
    assert_equal ['p', 't1', 2, 'full', 'a', 'opus', 'ok'],
                 log[0].values_at('project', 'topic', 'version', 'route', 'phase', 'model', 'status')
    assert_in_delta 0.5, log[0]['cost_usd']
    assert_equal 20, log[0]['tokens']['output']

    raw = File.join(@state, 'logs', 'p-t1', '02-b.jsonl')
    assert File.exist?(raw)
    assert(File.readlines(raw).any? { |l| l.include?('"type":"result"') })
    assert_includes output, '== result: success'
    assert_includes output, '-> Write:'
    refute_includes output, API_WARNING
  end

  def test_resume_skips_phases_with_output
    FileUtils.mkdir_p(outdir)
    File.write(outdir('a.md'), "done\n")
    assert run_topic, output
    assert_equal %w[b c], calls.map { |c| c['phase'] }
    assert_equal %w[b c], usage['phases'].map { |p| p['phase'] }
    assert_equal '', dirty("#{OUT_REL}/a.md")
    assert_includes git('log', '--format=%s'), 'review(t1): a output (runner)'
  end

  def test_missing_output_fails_and_stops
    plan(default_plan.merge('b' => { 'write' => [] }))
    refute run_topic
    assert_equal %w[a b], calls.map { |c| c['phase'] }
    refute File.exist?(outdir('c.md'))
    a, b = usage['phases']
    assert_equal 'ok', a['status']
    assert_equal 'failed', b['status']
    assert_match(/b\.md/, b['reason'])
    assert_equal %w[ok failed], usage_log.map { |l| l['status'] }
    assert_equal '', dirty("#{OUT_REL}/usage.json")
    assert_match(/FAIL/, output)

    plan(default_plan)
    assert run_topic, output
    assert_equal %w[a b b c], calls.map { |c| c['phase'] }
    assert_equal %w[ok failed ok ok], usage['phases'].map { |p| p['status'] }
  end

  def test_no_result_event_fails
    plan(default_plan.merge('b' => { 'write' => ['b.md'], 'no_result' => true }))
    refute run_topic
    assert_equal %w[a b], calls.map { |c| c['phase'] }
    b = usage['phases'].last
    assert_equal 'failed', b['status']
    assert_match(/no result/, b['reason'])

    plan(default_plan)
    assert run_topic, output
    assert_equal %w[a b b c], calls.map { |c| c['phase'] }
    assert_equal %w[ok failed ok ok], usage['phases'].map { |p| p['status'] }
  end

  def test_nonzero_exit_fails
    plan(default_plan.merge('b' => { 'write' => ['b.md'], 'exit' => 3 }))
    refute run_topic
    assert_equal %w[a b], calls.map { |c| c['phase'] }
    b = usage['phases'].last
    assert_match(/exit 3/, b['reason'])
    assert_in_delta 0.5, b['cost_usd']
  end

  def test_noise_on_stream_is_logged_raw
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'noise' => true }))
    assert run_topic, output
    assert_includes output, 'fake-claude: stderr noise'
    assert_includes File.read(File.join(@state, 'logs', 'p-t1', '01-a.jsonl')), 'fake-claude: stderr noise'
  end

  def test_uncommitted_output_committed_by_runner
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'commit' => false }))
    assert run_topic, output
    assert_includes git('log', '--format=%s'), 'review(t1): a output (runner)'
    assert_equal '', dirty("#{OUT_REL}/a.md")
  end

  def test_child_env_has_no_done_file
    ENV['REVIEW_DONE_FILE'] = File.join(@root, 'done')
    assert run_topic, output
    assert_equal [false, false, false], calls.map { |c| c['done_file_env'] }
    refute File.exist?(File.join(@root, 'done'))
  end

  def test_skip_if_skips_phase
    phases = PHASES.dup
    phases[2] = phases[2].merge('skip_if' => { 'file' => 'flag.md', 'match' => '^skip' })
    write_manifest(phases)
    FileUtils.mkdir_p(outdir)
    File.write(outdir('flag.md'), "skip\n")
    assert run_topic, output
    assert_equal %w[a b], calls.map { |c| c['phase'] }
    assert_equal %w[a b], usage['phases'].map { |p| p['phase'] }
  end

  def test_git_lock_retried
    plan(%w[a b c].to_h { |n| [n, { 'write' => ["#{n}.md"], 'commit' => false }] })
    lock = File.join(@ws, '.git', 'index.lock')
    File.write(lock, '')
    ok = run_topic(sleeper: lambda { |s|
      @slept << s
      FileUtils.rm_f(lock)
    })
    assert ok, output
    assert_equal [2], @slept
    assert_equal %w[a b c], calls.map { |c| c['phase'] }
    assert_equal '', dirty('p/findings')
  end

  def test_git_lock_gives_up
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'commit' => false }))
    lock = File.join(@ws, '.git', 'index.lock')
    File.write(lock, '')
    refute run_topic
    assert_equal %w[a], calls.map { |c| c['phase'] }
    assert(@slept.all? { |s| s == 2 })
    assert_includes output, 'retry 5/5'
    refute_includes output, 'retry 6/'
    assert_match(/FAILED: phase a: could not commit .*a\.md/, output)

    FileUtils.rm_f(lock)
    assert run_topic, output
    assert_equal %w[a a b c], calls.map { |c| c['phase'] }
    assert_equal '', dirty("#{OUT_REL}/a.md")
    assert_equal '', dirty('p/findings')
  end

  LIMIT_EPOCH = 1_800_000_000
  LIMIT_TEXT = "Claude AI usage limit reached|#{LIMIT_EPOCH}".freeze
  NOW = Time.at(LIMIT_EPOCH - 1000)

  def pause_file
    File.join(@state, 'paused')
  end

  def limit_plan(step)
    plan(default_plan.merge('b' => { 'write' => ['b.md'], 'limit_text' => LIMIT_TEXT }.merge(step)))
  end

  def test_limit_hit_pauses_and_retries
    limit_plan('limit_first' => true)
    seen = []
    ok = run_topic(clock: -> { NOW }, sleeper: lambda { |s|
      @slept << s
      seen << JSON.parse(File.read(pause_file))
    })
    assert ok, output
    assert_equal %w[a b b c], calls.map { |c| c['phase'] }
    assert_equal [1120], @slept
    assert_equal [{ 'until' => Time.at(LIMIT_EPOCH + 120).iso8601, 'by' => 'p-t1' }], seen
    refute File.exist?(pause_file)
    assert_equal %w[a b c], usage['phases'].map { |p| p['phase'] }
    assert_equal %w[ok ok ok], usage['phases'].map { |p| p['status'] }
    assert_equal %w[ok limit ok ok], usage_log.map { |l| l['status'] }
    assert_match(%r{usage limit in phase b, paused until .* \(retry 1/5\)}, output)
  end

  def test_limit_retries_exhausted_fails_phase
    limit_plan('limit_times' => 6)
    refute run_topic(clock: -> { NOW })
    assert_equal %w[a b b b b b b], calls.map { |c| c['phase'] }
    assert_equal [1120] * 5, @slept
    a, b, *rest = usage['phases']
    assert_empty rest
    assert_equal 'ok', a['status']
    assert_equal ['failed', 'usage limit, retries exhausted'], b.values_at('status', 'reason')
    assert_equal %w[ok limit limit limit limit limit failed], usage_log.map { |l| l['status'] }
    assert_equal Time.at(LIMIT_EPOCH + 120).iso8601, JSON.parse(File.read(pause_file))['until']
    assert_includes output, 'FAILED: phase b: usage limit, retries exhausted'
    refute File.exist?(outdir('c.md'))
  end

  def test_limit_reset_unparsable_waits_an_hour
    limit_plan('limit_first' => true, 'limit_text' => 'Claude AI usage limit reached, resets 3:75pm')
    assert run_topic(clock: -> { NOW }), output
    assert_equal [3600 + 120], @slept
    assert_equal %w[a b b c], calls.map { |c| c['phase'] }
  end

  def test_error_without_limit_text_fails_without_pause
    limit_plan('limit_first' => true, 'limit_text' => 'API Error: 500')
    refute run_topic
    assert_equal %w[a b], calls.map { |c| c['phase'] }
    assert_empty @slept
    refute File.exist?(pause_file)
    assert_match(/claude error/, usage['phases'].last['reason'])
  end

  def test_warns_on_api_key
    ENV['ANTHROPIC_API_KEY'] = 'sk-test'
    assert run_topic, output
    assert_includes output, API_WARNING
  end

  def test_render_prints_prompt_without_claude
    v1 = File.join(@ws, 'p', 'findings', 't1', 'v1')
    FileUtils.mkdir_p(v1)
    File.write(File.join(v1, '05-summary.md'), "x\n")
    text = runner.render(project: 'p', topic: 't1', phase: 'b')
    assert_includes text, "Phase: b (2 of 3)\n"
    assert_includes text, "Output directory: #{OUT_REL}\n"
    assert_includes text, "Previous reviewed version: p/findings/t1/v1\n"
    assert_includes text, "Do b for t1 into #{OUT_REL}\n"
    assert_empty calls
    refute File.exist?(outdir)
    refute File.exist?(File.join(@ws, 'p', 'current-reviews'))
  end

  def test_render_unknown_phase_raises
    assert_raises(ReviewRun::RunError) { runner.render(project: 'p', topic: 't1', phase: 'zz') }
  end

  def test_missing_phases_config_fails
    File.write(File.join(@ws, 'p', 'project.yaml'), "name: p\n")
    refute run_topic
    assert_includes output, 'review.phases'
    assert_empty calls
  end

  def cli(*args)
    env = { 'WORKSPACE_DIR' => @ws, 'STATE_DIR' => @state, 'CLAUDE_BIN' => FAKE, 'TMUX' => nil }
    Open3.capture2e(env, CLI, *args, chdir: @root)
  end

  def test_cli_run_touches_done_file
    done = File.join(@root, 'signals', 'p-t1.done')
    ENV['REVIEW_DONE_FILE'] = done
    out, st = cli('--done-file', done, 'p', 't1')
    assert st.success?, out
    assert File.exist?(done)
    assert_equal [false, false, false], calls.map { |c| c['done_file_env'] }
    assert File.exist?(outdir('metadata.json'))
  end

  def test_cli_failure_touches_done_file
    plan(default_plan.merge('a' => { 'write' => [] }))
    done = File.join(@root, 'p-t1.done')
    out, st = cli('--done-file', done, 'p', 't1')
    refute st.success?, out
    assert File.exist?(done)
  end

  def test_cli_non_ascii_stream_under_c_locale
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'text' => "caf\u00e9 \u2014 ok" }))
    out, st = Open3.capture2e({ 'WORKSPACE_DIR' => @ws, 'STATE_DIR' => @state, 'CLAUDE_BIN' => FAKE,
                                'TMUX' => nil, 'LC_ALL' => 'C', 'LANG' => 'C' },
                              CLI, 'p', 't1', chdir: @root)
    assert st.success?, out
    assert_equal %w[ok ok ok], usage['phases'].map { |p| p['status'] }
  end

  def test_cli_render
    out, st = cli('--render', 'a', 'p', 't1')
    assert st.success?, out
    assert_includes out, "Phase: a (1 of 3)\n"
    assert_empty calls
  end
end
