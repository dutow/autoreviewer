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
  FAKE_CODEX = File.join(ROOT, 'test', 'fixtures', 'review_run', 'fake-codex')
  CLI = File.join(ROOT, 'bin', 'review-run')
  ENV_KEYS = %w[FAKE_CLAUDE_PLAN FAKE_CLAUDE_CALLS REVIEW_DONE_FILE ANTHROPIC_API_KEY OPENAI_API_KEY CODEX_API_KEY
                TMUX].freeze
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

  def write_manifest(phases, route: 'full')
    dir = File.join(@ws, '.claude', 'review-phases', 'p')
    FileUtils.mkdir_p(dir)
    phases.each { |ph| File.write(File.join(dir, ph['prompt']), "Do #{ph['name']} for $ARGUMENTS into $OUTDIR\n") }
    File.write(File.join(dir, 'phases.yaml'), YAML.dump('default_model' => 'opus', 'routes' => { route => phases }))
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

  def runner(sleeper: ->(s) { @slept << s }, clock: -> { Time.now }, **opts)
    @out = StringIO.new
    ReviewRun::Runner.new(base_dir: @base, workspace_dir: @ws, state_dir: @state,
                          claude_bin: FAKE, codex_bin: FAKE_CODEX, out: @out, sleeper: sleeper, clock: clock, **opts)
  end

  def project_yaml(review)
    File.write(File.join(@ws, 'p', 'project.yaml'),
               YAML.dump('name' => 'p', 'review' => { 'phases' => 'p' }.merge(review)))
    git('add', 'p/project.yaml')
    git('commit', '-q', '-m', 'project.yaml')
  end

  # previous reviewed version v1; agent nil: no usage.json
  def prev_usage(agent)
    dir = File.join(@ws, 'p', 'findings', 't1', 'v1')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, '05-summary.md'), "x\n")
    path = File.join(dir, 'usage.json')
    if agent
      File.write(path, JSON.generate('phases' => [{ 'phase' => 'a', 'agent' => agent, 'status' => 'ok' }]))
    else
      FileUtils.rm_f(path)
    end
    git('add', '-A', '--', 'p/findings/t1/v1')
    git('commit', '-q', '--allow-empty', '-m', 'prev')
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
    assert_equal %w[time project topic version route phase agent model status cost_usd tokens].sort, log[0].keys.sort
    assert_equal ['p', 't1', 2, 'full', 'a', 'opus', 'ok'],
                 log[0].values_at('project', 'topic', 'version', 'route', 'phase', 'model', 'status')
    assert_in_delta 0.5, log[0]['cost_usd']
    assert_equal 20, log[0]['tokens']['output']

    raw = File.join(@state, 'logs', 'p-t1-v2', '02-b.jsonl')
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

  def test_resume_reruns_phase_interrupted_by_limit
    FileUtils.mkdir_p(outdir)
    File.write(outdir('a.md'), "partial\n")
    File.write(outdir('usage.json'), JSON.generate('phases' => [
                                                     { 'phase' => 'a', 'status' => 'limit', 'cost_usd' => 0.1, 'duration_ms' => 1,
                                                       'tokens' => { 'input' => 1, 'output' => 1, 'cache_read' => 0, 'cache_write' => 0 } }
                                                   ]))
    assert run_topic, output
    assert_equal %w[a b c], calls.map { |c| c['phase'] }
    assert_equal %w[limit ok ok ok], usage['phases'].map { |p| p['status'] }
  end

  def test_finished_review_without_usage_creates_none
    FileUtils.mkdir_p(outdir)
    %w[a.md b.md c.md].each { |f| File.write(outdir(f), "done\n") }
    git('add', '-f', OUT_REL)
    git('commit', '-q', '-m', 'old review')
    assert run_topic, output
    assert_empty calls
    refute File.exist?(outdir('usage.json'))
    assert_empty git('ls-files', "#{OUT_REL}/usage.json")
    refute_includes git('log', '--format=%s'), 'review(t1): add usage'
  end

  def test_commit_done_by_other_session_counts_as_success
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'commit' => false }))
    r = runner
    ws = @ws
    r.define_singleton_method(:git) do |*args|
      return super(*args) unless args.first == 'commit'

      Open3.capture2e('git', 'commit', '-q', '-m', 'other session', '--', *args.drop_while { |a| a != '--' }.drop(1),
                      chdir: ws)
      [false, 'nothing added to commit']
    end
    ok = nil
    capture_io { ok = r.run_topic(project: 'p', topic: 't1') }
    assert ok, output
    assert_equal %w[a b c], calls.map { |c| c['phase'] }
    assert_includes git('log', '--format=%s'), 'other session'
    assert_equal '', dirty('p/findings')
  end

  def test_commit_failure_with_dirty_path_still_fails
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'commit' => false }))
    r = runner
    r.define_singleton_method(:git) do |*args|
      args.first == 'commit' ? [false, 'hook rejected'] : super(*args)
    end
    ok = nil
    capture_io { ok = r.run_topic(project: 'p', topic: 't1') }
    refute ok
    assert_match(/FAILED: phase a: could not commit .*a\.md/, output)
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
    assert_includes File.read(File.join(@state, 'logs', 'p-t1-v2', '01-a.jsonl')), 'fake-claude: stderr noise'
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
    assert_equal [{ 'REVIEW_RUN' => '1', 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS' => '1' }] * 3, calls.map { |c| c['env'] }
    refute File.exist?(File.join(@root, 'done'))
  end

  def test_replay_flag_reaches_prompt
    assert run_topic(replay: true), output
    assert_equal [true, true, true], calls.map { |c| c['replay_note'] }
  end

  def test_no_replay_note_by_default
    assert run_topic, output
    assert_equal [false, false, false], calls.map { |c| c['replay_note'] }
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
  DOT = "\u00b7".freeze
  LIMIT_TEXT = "You've hit your 5-hour limit #{DOT} resets 3pm (Europe/Budapest)".freeze
  LIMIT_EVENT = { 'status' => 'rejected', 'resetsAt' => LIMIT_EPOCH, 'rateLimitType' => 'five_hour' }.freeze
  NOW = Time.at(LIMIT_EPOCH - 1000)

  def pause_file
    File.join(@state, 'paused')
  end

  def limit_plan(step)
    plan(default_plan.merge('b' => { 'write' => ['b.md'], 'limit_text' => LIMIT_TEXT,
                                     'limit_event' => LIMIT_EVENT }.merge(step)))
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
    assert_equal %w[a b b c], usage['phases'].map { |p| p['phase'] }
    assert_equal %w[ok limit ok ok], usage['phases'].map { |p| p['status'] }
    lim = usage['phases'][1]
    assert_equal 'sonnet', lim['model']
    assert_in_delta 0.01, lim['cost_usd']
    assert_equal 2, lim['tokens']['output']
    assert_in_delta 1.51, usage['total']['cost_usd']
    assert_equal %w[ok limit ok ok], usage_log.map { |l| l['status'] }
    assert_match(%r{usage limit in phase b, paused until .* \(retry 1/5\)}, output)
  end

  def test_limit_retries_exhausted_fails_phase
    limit_plan('limit_times' => 6)
    refute run_topic(clock: -> { NOW })
    assert_equal %w[a b b b b b b], calls.map { |c| c['phase'] }
    assert_equal [1120] * 5, @slept
    a, *lims, b = usage['phases']
    assert_equal 'ok', a['status']
    assert_equal %w[limit] * 5, lims.map { |l| l['status'] }
    assert_equal ['failed', 'usage limit, retries exhausted'], b.values_at('status', 'reason')
    assert_equal %w[ok limit limit limit limit limit failed], usage_log.map { |l| l['status'] }
    assert_equal Time.at(LIMIT_EPOCH + 120).iso8601, JSON.parse(File.read(pause_file))['until']
    assert_includes output, 'FAILED: phase b: usage limit, retries exhausted'
    refute File.exist?(outdir('c.md'))
  end

  RANGE = 'abcdef1234567..1234567abcdef'.freeze

  def setup_commits
    File.write(File.join(@ws, 'p', 'project.yaml'), "name: p\nreview:\n  phases: p\ncommit_review:\n  command: ns:rev\n")
    dir = File.join(@ws, '.claude', 'commands', 'ns')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'rev.md'), "---\ndescription: x\n---\nReview $ARGUMENTS now\n")
  end

  def run_commits(**kw)
    r = runner(**kw)
    ok = nil
    capture_io { ok = r.run_commits(project: 'p', range: RANGE) }
    ok
  end

  def test_commits_mode_logs_usage_only
    setup_commits
    assert run_commits, output
    assert_equal %w[commits], calls.map { |c| c['phase'] }
    assert_includes calls.first['argv'], 'opus'
    assert_equal 1, usage_log.size
    e = usage_log.first
    assert_equal ['p', RANGE, nil, 'commits', 'commits', 'opus', 'ok', 0.5],
                 e.values_at('project', 'topic', 'version', 'route', 'phase', 'model', 'status', 'cost_usd')
    assert File.exist?(File.join(@state, 'logs', 'p-commits-abcdef1-1234567', 'commits.jsonl'))
    refute File.exist?(File.join(@ws, 'p', 'findings'))
  end

  def test_commits_mode_failure_and_missing_command
    setup_commits
    plan('commits' => { 'exit' => 1 })
    refute run_commits
    assert_equal ['failed'], usage_log.map { |l| l['status'] }
    File.write(File.join(@ws, 'p', 'project.yaml'), "name: p\n")
    refute run_commits
    assert_includes output, 'commit_review.command'
  end

  def test_commits_mode_limit_pauses_with_own_window
    setup_commits
    plan('commits' => { 'limit_first' => true, 'limit_text' => LIMIT_TEXT, 'limit_event' => LIMIT_EVENT })
    seen = []
    ok = run_commits(clock: -> { NOW }, sleeper: ->(s) { @slept << s; seen << JSON.parse(File.read(pause_file)) })
    assert ok, output
    assert_equal [1120], @slept
    assert_equal 'p-commits-abcdef1-1234567', seen.first['by']
    refute File.exist?(pause_file)
    assert_equal %w[limit ok], usage_log.map { |l| l['status'] }
  end

  def test_foreign_pause_left_in_place
    limit_plan('limit_first' => true)
    sleeper = lambda do |s|
      @slept << s
      ReviewRun::Pause.new(pause_file).set(Time.at(LIMIT_EPOCH + 5000), by: 'other-window')
    end
    assert run_topic(clock: -> { NOW }, sleeper: sleeper), output
    assert_equal 'other-window', JSON.parse(File.read(pause_file))['by']
  end

  def test_past_reset_still_waits_floor
    limit_plan('limit_first' => true, 'limit_event' => LIMIT_EVENT.merge('resetsAt' => LIMIT_EPOCH - 1500))
    assert run_topic(clock: -> { NOW }), output
    assert_equal [300], @slept
  end

  def test_limit_text_only_reset_from_text
    now = Time.local(2026, 11, 20, 13, 0, 0)
    limit_plan('limit_first' => true, 'limit_event' => nil,
               'limit_text' => "You've hit your weekly limit #{DOT} resets Nov 24, 3pm (Europe/Budapest)")
    assert run_topic(clock: -> { now }), output
    assert_equal [(Time.local(2026, 11, 24, 15, 0, 0) + 120 - now).ceil], @slept
    assert_equal %w[a b b c], calls.map { |c| c['phase'] }
  end

  def test_limit_event_only_pauses_until_resets_at
    limit_plan('limit_first' => true, 'limit_text' => 'API Error: 429 rate_limit_error')
    assert run_topic(clock: -> { NOW }), output
    assert_equal [1120], @slept
    assert_equal %w[a b b c], calls.map { |c| c['phase'] }
  end

  def test_rejected_event_on_successful_run_does_not_pause
    plan(default_plan.merge('b' => { 'write' => ['b.md'], 'rate_limit' => LIMIT_EVENT }))
    assert run_topic(clock: -> { NOW }), output
    assert_empty @slept
    assert_equal %w[a b c], calls.map { |c| c['phase'] }
  end

  def test_limit_reset_unparsable_waits_an_hour
    limit_plan('limit_first' => true, 'limit_event' => nil, 'limit_text' => "You've hit your limit #{DOT} resets 3:75pm")
    assert run_topic(clock: -> { NOW }), output
    assert_equal [3600 + 120], @slept
    assert_equal %w[a b b c], calls.map { |c| c['phase'] }
  end

  def test_limit_text_without_reset_waits_an_hour
    limit_plan('limit_first' => true, 'limit_event' => nil, 'limit_text' => "You've hit your Opus limit")
    assert run_topic(clock: -> { NOW }), output
    assert_equal [3600 + 120], @slept
  end

  def test_error_without_limit_text_fails_without_pause
    ['API Error: 500', 'Server is temporarily limiting requests (not your usage limit)',
     "Context limit reached #{DOT} /compact or /clear to continue"].each do |text|
      FileUtils.rm_rf(outdir)
      FileUtils.rm_f(@calls_file)
      limit_plan('limit_first' => true, 'limit_event' => nil, 'limit_text' => text)
      refute run_topic, text
      assert_equal %w[a b], calls.map { |c| c['phase'] }, text
      assert_empty @slept, text
      refute File.exist?(pause_file), text
      assert_match(/claude error/, usage['phases'].last['reason'])
    end
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

  def cli(*args, env: {})
    env = { 'WORKSPACE_DIR' => @ws, 'STATE_DIR' => @state, 'CLAUDE_BIN' => FAKE, 'CODEX_BIN' => FAKE_CODEX,
            'TMUX' => nil }.merge(env)
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

  def test_cli_commits
    setup_commits
    _out, st = cli('--commits', 'p', RANGE)
    assert st.success?
    assert_equal %w[commits], calls.map { |c| c['phase'] }
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
    refute_includes out, 'Replay of a past review'
    assert_empty calls
  end

  def test_cli_replay_flag
    out, st = cli('--replay', '--render', 'a', 'p', 't1')
    assert st.success?, out
    assert_includes out, ReviewRun::Prompt::REPLAY_NOTE
    out, st = cli('--replay', 'p', 't1')
    assert st.success?, out
    assert_equal [true, true, true], calls.map { |c| c['replay_note'] }
  end

  def agents_of(list)
    list.map { |c| c['agent'] }
  end

  def reset_run
    FileUtils.rm_rf(outdir)
    FileUtils.rm_f(@calls_file)
  end

  def codex_pause_file
    File.join(@state, 'paused-codex')
  end

  def test_default_mode_is_claude_unchanged
    assert run_topic, output
    assert_equal %w[claude] * 3, agents_of(calls)
    assert_equal %w[claude] * 3, agents_of(usage['phases'])
    assert_equal %w[claude] * 3, agents_of(usage_log)
    refute usage.key?('codex_version')
    assert_includes output, 'agent claude (claude)'
  end

  def test_codex_mode_uses_codex_model_and_effort
    project_yaml('agent' => 'codex')
    assert run_topic, output
    assert_equal %w[codex] * 3, agents_of(calls)
    calls.each do |c|
      assert_equal %w[-m gpt-6.2-astra], c['argv'][c['argv'].index('-m'), 2]
      assert_includes c['argv'], 'model_reasoning_effort=xhigh'
    end
    u = usage
    assert_equal %w[codex] * 3, agents_of(u['phases'])
    assert_equal %w[gpt-6.2-astra] * 3, u['phases'].map { |p| p['model'] }
    assert_equal [nil] * 3, u['phases'].map { |p| p['cost_usd'] }
    assert_equal '9.9.9', u['codex_version']
    assert_nil u['total']['cost_usd']
    assert_equal 'codex', u['agent_mode']
    assert_equal %w[codex] * 3, agents_of(usage_log)
    assert_equal %w[gpt-6.2-astra] * 3, usage_log.map { |l| l['model'] }
  end

  def test_claude_model_override
    project_yaml('claude' => { 'model' => 'haiku' })
    assert run_topic, output
    assert_equal %w[haiku] * 3, calls.map { |c| c['argv'][c['argv'].index('--model') + 1] }
    assert_equal %w[haiku] * 3, usage['phases'].map { |p| p['model'] }
  end

  def test_alternate_flips_from_previous
    project_yaml('agent' => 'alternate')
    { 'claude' => 'codex', 'codex' => 'claude', nil => 'codex' }.each do |prev, want|
      reset_run
      prev_usage(prev)
      assert run_topic, output
      assert_equal [want] * 3, agents_of(calls), "previous #{prev.inspect}"
    end
  end

  def test_alternate_parity_without_previous
    project_yaml('agent' => 'alternate')
    assert run_topic, output
    assert_equal %w[codex] * 3, agents_of(calls)
    assert_includes output, 'agent codex (alternate)'
  end

  def test_alternate_resume_keeps_agent
    project_yaml('agent' => 'alternate')
    prev_usage('codex')
    FileUtils.mkdir_p(outdir)
    File.write(outdir('usage.json'), JSON.generate('phases' => [
                                                     { 'phase' => 'a', 'agent' => 'codex', 'status' => 'failed',
                                                       'reason' => 'x', 'cost_usd' => nil, 'duration_ms' => 1 }
                                                   ]))
    assert run_topic, output
    assert_equal %w[codex] * 3, agents_of(calls)
    assert_equal %w[a b c], calls.map { |c| c['phase'] }
  end

  def test_alternate_switches_on_limit
    project_yaml('agent' => 'alternate')
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'limit_times' => 1 }))
    assert run_topic(clock: -> { NOW }), output
    assert_equal %w[codex claude claude claude], agents_of(calls)
    assert_equal %w[a a b c], calls.map { |c| c['phase'] }
    assert_empty @slept
    ph = usage['phases']
    assert_equal [%w[a codex limit], %w[a claude ok], %w[b claude ok], %w[c claude ok]],
                 ph.map { |p| p.values_at('phase', 'agent', 'status') }
    assert_equal 'opus', ph[1]['model']
    assert File.exist?(codex_pause_file)
    refute File.exist?(pause_file)
    assert_includes output, 'usage limit on codex, switching to claude'
    assert_equal %w[codex claude claude claude], agents_of(usage_log)
  end

  def test_alternate_both_paused_waits_earlier
    project_yaml('agent' => 'alternate')
    ReviewRun::Pause.for(@state, 'claude').set(NOW + 7200, by: 'other')
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'limit_times' => 1,
                                      'limit_text' => "You've hit your usage limit." }))
    assert run_topic(clock: -> { NOW }), output
    assert_equal [3720], @slept
    assert_equal %w[codex codex codex codex], agents_of(calls)
    assert_equal %w[a a b c], calls.map { |c| c['phase'] }
    refute_includes output, 'switching to'
    refute File.exist?(codex_pause_file)
    assert_equal 'other', JSON.parse(File.read(pause_file))['by']
  end

  def test_alternate_both_paused_other_earlier_runs_on_it
    project_yaml('agent' => 'alternate')
    ReviewRun::Pause.for(@state, 'claude').set(NOW + 1800, by: 'other')
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'limit_times' => 1,
                                      'limit_text' => "You've hit your usage limit." }))
    assert run_topic(clock: -> { NOW }), output
    assert_equal [1800], @slept
    assert_equal %w[codex claude claude claude], agents_of(calls)
  end

  def test_claude_mode_never_switches
    project_yaml('agent' => 'claude')
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'limit_times' => 1 }))
    assert run_topic(clock: -> { NOW }), output
    assert_equal 1, @slept.size
    assert_equal %w[claude] * 4, agents_of(calls)
    refute File.exist?(codex_pause_file)
  end

  def test_forced_agent
    assert run_topic(agent: 'codex'), output
    assert_equal %w[codex] * 3, agents_of(calls)
    assert_includes output, 'agent codex (claude, forced)'

    reset_run
    project_yaml('agent' => 'alternate')
    prev_usage('codex')
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'limit_times' => 1 }))
    assert run_topic(agent: 'codex', clock: -> { NOW }), output
    assert_equal %w[codex] * 4, agents_of(calls)
    assert_equal 1, @slept.size
    refute_includes output, 'switching to'
  end

  def test_codex_missing_fails_cleanly
    project_yaml('agent' => 'codex')
    refute run_topic(codex_bin: '/nonexistent/codex')
    assert_includes output, 'ERROR: could not run /nonexistent/codex'
    refute_includes output, 'Errno'
    assert_equal ['failed', 'no result event (codex did not start)'], usage['phases'].last.values_at('status', 'reason')
    refute usage.key?('codex_version')

    done = File.join(@root, 'p-t1.done')
    out, st = cli('--done-file', done, 'p', 't1', env: { 'CODEX_BIN' => '/nonexistent/codex' })
    refute st.success?, out
    assert_includes out, 'could not run /nonexistent/codex'
    assert File.exist?(done)
  end

  def test_codex_unparseable_reset_waits_fallback
    project_yaml('agent' => 'codex')
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'limit_times' => 1,
                                      'limit_text' => "You've hit your usage limit." }))
    assert run_topic(clock: -> { NOW }), output
    assert_equal [3720], @slept
    assert_equal %w[codex] * 4, agents_of(calls)
    assert_equal %w[limit ok ok ok], usage['phases'].map { |p| p['status'] }
    refute File.exist?(codex_pause_file)
  end

  def test_long_limit_notifies_in_single_mode
    path = ENV['PATH']
    stub = File.join(@root, 'stub-bin')
    rec = File.join(@root, 'tmux.args')
    FileUtils.mkdir_p(stub)
    File.write(File.join(stub, 'tmux'), "#!/bin/sh\necho \"$@\" >> #{rec}\n")
    File.chmod(0o755, File.join(stub, 'tmux'))
    ENV['PATH'] = "#{stub}:#{path}"
    ENV['TMUX'] = 'fake'
    reset = (NOW + (3 * 86_400)).to_i
    plan(default_plan.merge('a' => { 'write' => ['a.md'], 'limit_times' => 2,
                                      'limit_event' => LIMIT_EVENT.merge('resetsAt' => reset) }))
    assert run_topic(clock: -> { NOW }), output
    assert_equal 2, @slept.size
    windows = File.readlines(rec)
    assert_equal 1, windows.size, windows.join
    assert_includes windows.first, '-n LIMIT-claude '
    assert_includes windows.first, 'claude\ usage\ limit\ until'
  ensure
    ENV['PATH'] = path
  end

  def test_short_limit_does_not_notify
    r = runner(clock: -> { NOW })
    seen = []
    r.define_singleton_method(:notify) { |w, _m| seen << w }
    limit_plan('limit_first' => true)
    ok = nil
    capture_io { ok = r.run_topic(project: 'p', topic: 't1') }
    assert ok, output
    assert_empty seen
  end

  def test_bad_agent_config_fails
    project_yaml('agent' => 'both')
    refute run_topic
    assert_includes output, 'review.agent'
    assert_empty calls
  end

  def test_warns_on_codex_key
    ENV['OPENAI_API_KEY'] = 'sk-test'
    assert run_topic, output
    refute_includes output, 'OPENAI_API_KEY'
    reset_run
    project_yaml('agent' => 'alternate')
    assert run_topic, output
    assert_includes output, 'WARNING: OPENAI_API_KEY/CODEX_API_KEY is set; codex exec may bill the API key'
  end

  def test_codex_without_result_has_no_cost
    project_yaml('agent' => 'codex')
    refute run_topic(codex_bin: '/nonexistent/codex')
    u = usage
    assert_nil u['phases'].last['cost_usd']
    assert_nil u['total']['cost_usd']
    assert_equal [nil], usage_log.map { |l| l['cost_usd'] }
  end

  def test_cli_agent_flag
    out, st = cli('--agent', 'codex', 'p', 't1')
    assert st.success?, out
    assert_equal %w[codex] * 3, agents_of(calls)
    out, st = cli('--agent', 'gemini', 'p', 't1')
    refute st.success?
    assert_includes out, 'invalid argument'
  end

  def both_setup(review = {})
    write_manifest([{ 'name' => 'review', 'prompt' => '01-review.md', 'output' => '05-summary.md' }], route: 'single')
    project_yaml({ 'route' => 'single', 'agent' => 'both' }.merge(review))
    both_plan
  end

  def both_plan(steps = {})
    plan({ 'discovery' => { 'write' => %w[01-design-review.md 02-code-review.md], 'commit' => false },
           'review' => { 'write' => ['05-summary.md'] } }.merge(steps))
  end

  def phase_agents
    calls.map { |c| c.values_at('phase', 'agent') }
  end

  def usage_rows(*keys)
    usage['phases'].map { |p| p.values_at('phase', 'agent', 'status', *keys) }
  end

  def test_both_runs_discovery_then_primary
    both_setup
    r = runner
    prompts = []
    r.define_singleton_method(:run_session) do |rv, phase, prompt, log, usage|
      prompts << prompt
      super(rv, phase, prompt, log, usage)
    end
    ok = nil
    capture_io { ok = r.run_topic(project: 'p', topic: 't1') }
    assert ok, output
    assert_equal [%w[discovery codex], %w[review claude]], phase_agents
    d, rev = calls
    assert_equal "#{OUT_REL}/codex", d['outdir']
    assert d['discovery_note']
    refute d['note']
    assert_equal OUT_REL, rev['outdir']
    assert rev['note']
    refute rev['discovery_note']
    assert_includes prompts[0], "Do review for t1 into #{OUT_REL}/codex\n"
    assert_includes prompts[0], ReviewRun::Prompt::DISCOVERY_NOTE
    assert_includes prompts[1], ReviewRun::Prompt.primary_note("#{OUT_REL}/codex")
    prompts.each { |pr| assert_includes pr, "\nRun without stopping for user input.\n" }

    assert_equal %W[#{OUT_REL}/codex/01-design-review.md #{OUT_REL}/codex/02-code-review.md],
                 git('ls-files', "#{OUT_REL}/codex").lines.map(&:strip)
    assert_includes git('log', '--format=%s'), 'review(t1): codex discovery (runner)'
    assert_equal '', dirty('p/findings')
    u = usage
    assert_equal [%w[discovery codex ok gpt-6.2-astra], %w[review claude ok opus]], usage_rows('model')
    assert_equal 'both', u['agent_mode']
    refute u.key?('degraded')
    refute u.key?('discovery_base')
    assert_equal %w[01-discovery.jsonl 02-review.jsonl], Dir.children(File.join(@state, 'logs', 'p-t1-v2')).sort
    assert_includes output, 'agent claude (both, discovery on codex)'
    assert_includes output, '=== phase discovery (1 of 2), agent codex'
  end

  def test_both_primary_codex
    both_setup('primary' => 'codex')
    assert run_topic, output
    assert_equal [%w[discovery claude], %w[review codex]], phase_agents
    assert_equal "#{OUT_REL}/claude", calls[0]['outdir']
    assert calls[1]['note']
    assert_equal '', dirty("#{OUT_REL}/claude")
    assert_includes git('log', '--format=%s'), 'review(t1): claude discovery (runner)'
  end

  def test_both_guard_fails_on_stray_write
    both_setup
    stray = "#{OUT_REL}/02-code-review.md"
    both_plan('discovery' => { 'write' => ['02-code-review.md'], 'files' => { File.join(@ws, stray) => 'x' } })
    refute run_topic
    assert_equal %w[discovery], calls.map { |c| c['phase'] }
    msg = "discovery wrote outside #{OUT_REL}/codex: #{stray}"
    assert_includes output, msg
    assert_equal [['discovery', 'codex', 'failed', msg]], usage_rows('reason')
    assert File.exist?(File.join(@ws, stray))
  end

  def test_both_guard_catches_committed_stray
    both_setup
    stray = "#{OUT_REL}/00-overview.md"
    both_plan('discovery' => { 'write' => ['02-code-review.md'], 'files' => { File.join(@ws, stray) => 'x' },
                               'commit_files' => true })
    refute run_topic
    assert_includes output, "discovery wrote outside #{OUT_REL}/codex: #{stray}"
    assert_equal '', dirty(stray)
  end

  def test_both_guard_ignores_other_commits_and_existing_files
    both_setup
    FileUtils.mkdir_p(outdir)
    File.write(outdir('old.md'), "old\n")
    git('add', "#{OUT_REL}/old.md")
    git('commit', '-q', '-m', 'old')
    other = 'p/findings/t2/v1/x.md'
    both_plan('discovery' => { 'write' => ['02-code-review.md'], 'files' => { File.join(@ws, other) => 'x' },
                               'commit_files' => true })
    assert run_topic, output
    assert_equal %w[discovery review], calls.map { |c| c['phase'] }
    assert_equal '', dirty(other)
    assert_includes git('log', '--format=%s'), 'fake discovery files'
  end

  def test_both_resume_skips_discovery
    both_setup
    both_plan('review' => { 'write' => ['05-summary.md'], 'exit' => 1 })
    refute run_topic
    assert_equal %w[discovery review], calls.map { |c| c['phase'] }

    both_plan
    assert run_topic, output
    assert_equal %w[discovery review review], calls.map { |c| c['phase'] }
    assert calls.last['note']
    assert_includes output, 'skip discovery: codex/02-code-review.md exists'
    assert_equal %w[ok failed ok], usage['phases'].map { |p| p['status'] }
  end

  def test_both_discovery_long_limit_skips
    both_setup
    ReviewRun::Pause.for(@state, 'codex').set(NOW + (3 * 86_400), by: 'other')
    assert run_topic(clock: -> { NOW }), output
    assert_equal [%w[review claude]], phase_agents
    refute calls.first['note']
    assert_empty @slept
    assert_equal [['discovery', 'codex', 'skipped', 'usage limit (long)'], ['review', 'claude', 'ok', nil]],
                 usage_rows('reason')
    assert_equal true, usage['degraded']
    refute usage.key?('discovery_base')
  end

  def test_both_resume_after_skipped_discovery
    both_setup
    ReviewRun::Pause.for(@state, 'codex').set(NOW + (3 * 86_400), by: 'other')
    both_plan('review' => { 'write' => ['05-summary.md'], 'exit' => 1 })
    refute run_topic(clock: -> { NOW })
    assert_equal [%w[discovery codex skipped], %w[review claude failed]], usage_rows

    ReviewRun::Pause.for(@state, 'codex').clear
    FileUtils.mkdir_p(outdir('codex'))
    File.write(outdir('codex', '02-code-review.md'), "partial\n")
    both_plan
    assert run_topic(clock: -> { NOW }), output
    assert_equal [%w[review claude], %w[review claude]], phase_agents
    assert_includes output, 'skip discovery: skipped earlier'
    refute calls.last['note']
    assert_equal true, usage['degraded']
  end

  def test_both_stray_of_failed_discovery_never_accepted
    both_setup
    stray = "#{OUT_REL}/05-summary.md"
    msg = "discovery wrote outside #{OUT_REL}/codex: #{stray}"
    both_plan('discovery' => { 'write' => [], 'files' => { File.join(@ws, stray) => 'codex summary' },
                               'commit_files' => true })
    refute run_topic
    assert_includes output, "FAILED: phase discovery: #{msg}"
    assert_equal [['discovery', 'codex', 'failed', msg]], usage_rows('reason')
    assert usage['discovery_base']

    both_plan
    refute run_topic
    assert_includes output, "FAILED: phase discovery: #{msg}"
    refute_includes output, 'skip review'
    assert_equal %w[discovery discovery], calls.map { |c| c['phase'] }

    git('rm', '-q', stray)
    git('commit', '-q', '-m', 'drop stray')
    assert run_topic, output
    assert_equal [%w[discovery codex]] * 3 + [%w[review claude]], phase_agents
    refute usage.key?('discovery_base')
  end

  def test_both_guard_runs_on_session_failure
    both_setup
    stray = "#{OUT_REL}/00-overview.md"
    both_plan('discovery' => { 'write' => ['02-code-review.md'], 'exit' => 1,
                               'files' => { File.join(@ws, stray) => 'x' } })
    refute run_topic
    msg = "discovery wrote outside #{OUT_REL}/codex: #{stray}"
    assert_includes output, "FAILED: phase discovery: #{msg}"
    assert_equal [['discovery', 'codex', 'failed', msg]], usage_rows('reason')
  end

  def test_both_guard_runs_before_long_skip
    both_setup
    base = git('rev-parse', 'HEAD').strip
    stray = "#{OUT_REL}/05-summary.md"
    FileUtils.mkdir_p(outdir)
    File.write(File.join(@ws, stray), "codex summary\n")
    git('add', stray)
    git('commit', '-q', '-m', 'stray of a killed discovery')
    File.write(outdir('usage.json'), JSON.generate('discovery_base' => base, 'phases' => [
                                                     { 'phase' => 'discovery', 'agent' => 'codex', 'status' => 'limit',
                                                       'cost_usd' => nil, 'duration_ms' => 1 }
                                                   ]))
    ReviewRun::Pause.for(@state, 'codex').set(NOW + (3 * 86_400), by: 'other')
    refute run_topic(clock: -> { NOW })
    assert_empty calls
    assert_includes output, "FAILED: phase discovery: discovery wrote outside #{OUT_REL}/codex: #{stray}"
    refute_includes output, 'discovery skipped'
    assert_equal %w[limit failed], usage['phases'].map { |p| p['status'] }
    refute usage.key?('degraded')
  end

  def test_both_base_gone_from_history_starts_over
    both_setup
    FileUtils.mkdir_p(outdir)
    File.write(outdir('usage.json'), JSON.generate('discovery_base' => 'f' * 40, 'phases' => []))
    assert run_topic, output
    assert_includes output, 'WARNING: discovery base ffffffffffff not in history, guard starts from HEAD'
    assert_equal %w[discovery review], calls.map { |c| c['phase'] }
    refute usage.key?('discovery_base')
  end

  def test_both_discovery_long_limit_hit_skips
    both_setup
    both_plan('discovery' => { 'write' => ['02-code-review.md'], 'limit_times' => 1,
                               'limit_text' => "You've hit your usage limit. Try again in 3 days." })
    assert run_topic(clock: -> { NOW }), output
    assert_equal [%w[discovery codex], %w[review claude]], phase_agents
    refute calls.last['note']
    assert_empty @slept
    assert_equal [%w[discovery codex limit], %w[discovery codex skipped], %w[review claude ok]], usage_rows
    assert_equal true, usage['degraded']
    assert File.exist?(codex_pause_file)
  end

  def test_both_discovery_short_limit_waits
    both_setup
    both_plan('discovery' => { 'write' => ['02-code-review.md'], 'limit_times' => 1,
                               'limit_text' => "You've hit your usage limit. Try again in 1 hour." })
    assert run_topic(clock: -> { NOW }), output
    assert_equal [3720], @slept
    assert_equal [%w[discovery codex], %w[discovery codex], %w[review claude]], phase_agents
    assert calls.last['note']
    assert_equal [%w[discovery codex limit], %w[discovery codex ok], %w[review claude ok]], usage_rows
    refute usage.key?('degraded')
    refute File.exist?(codex_pause_file)
  end

  def test_both_primary_long_limit_runs_on_other
    both_setup
    reset = (NOW + (3 * 86_400)).to_i
    both_plan('review' => { 'write' => ['05-summary.md'], 'limit_times' => 1, 'limit_agent' => 'claude',
                            'limit_event' => LIMIT_EVENT.merge('resetsAt' => reset, 'rateLimitType' => 'seven_day') })
    assert run_topic(clock: -> { NOW }), output
    assert_equal [%w[discovery codex], %w[review claude], %w[review codex]], phase_agents
    assert calls[1]['note']
    refute calls[2]['note']
    assert_empty @slept
    assert_equal [%w[discovery codex ok], %w[review claude limit], %w[review codex ok]], usage_rows
    assert_equal true, usage['degraded']
    assert_includes output, 'primary claude long-limited, review runs on codex alone'
    assert File.exist?(pause_file)
  end

  def test_both_primary_long_paused_at_start_runs_on_other
    both_setup
    ReviewRun::Pause.for(@state, 'claude').set(NOW + (3 * 86_400), by: 'other')
    assert run_topic(clock: -> { NOW }), output
    assert_equal [%w[discovery codex], %w[review codex]], phase_agents
    refute calls.last['note']
    assert_equal true, usage['degraded']
  end

  def test_both_all_long_waits_for_earlier
    both_setup
    ReviewRun::Pause.for(@state, 'claude').set(NOW + (3 * 86_400), by: 'other')
    ReviewRun::Pause.for(@state, 'codex').set(NOW + (2 * 86_400), by: 'other')
    assert run_topic(clock: -> { NOW }), output
    assert_equal [2 * 86_400], @slept
    assert_equal [%w[review codex]], phase_agents
    refute calls.last['note']
    assert_equal [%w[discovery codex skipped], %w[review codex ok]], usage_rows
    assert_equal true, usage['degraded']
  end

  def test_both_short_primary_limit_waits
    both_setup
    both_plan('review' => { 'write' => ['05-summary.md'], 'limit_times' => 1, 'limit_agent' => 'claude',
                            'limit_event' => LIMIT_EVENT })
    assert run_topic(clock: -> { NOW }), output
    assert_equal [1120], @slept
    assert_equal [%w[discovery codex], %w[review claude], %w[review claude]], phase_agents
    assert calls.last['note']
    refute usage.key?('degraded')
  end

  def test_forced_agent_in_both_mode_runs_single
    both_setup
    assert run_topic(agent: 'claude'), output
    assert_equal [%w[review claude]], phase_agents
    assert_equal OUT_REL, calls.first['outdir']
    refute calls.first['note']
    refute calls.first['discovery_note']
    assert_equal %w[review], usage['phases'].map { |p| p['phase'] }
  end

  def test_both_needs_one_phase_route
    write_manifest(PHASES, route: 'single')
    project_yaml('route' => 'single', 'agent' => 'both')
    refute run_topic
    assert_includes output, 'review.agent both needs a one-phase route'
    assert_empty calls
    refute File.exist?(outdir)
  end

  def test_both_guard_reads_git_stdout_only
    both_setup
    path = ENV['PATH']
    real = path.split(File::PATH_SEPARATOR).map { |d| File.join(d, 'git') }.find { |f| File.executable?(f) }
    stub = File.join(@root, 'git-bin')
    FileUtils.mkdir_p(stub)
    File.write(File.join(stub, 'git'), <<~SH)
      #!/bin/sh
      case " $* " in *' -z '*|' rev-parse '*) echo 'warning: noise' >&2 ;; esac
      exec #{real} "$@"
    SH
    File.chmod(0o755, File.join(stub, 'git'))
    ENV['PATH'] = "#{stub}:#{path}"
    assert run_topic, output
    assert_equal %w[discovery review], calls.map { |c| c['phase'] }
  ensure
    ENV['PATH'] = path
  end

  def test_both_guard_exempts_preexisting_dirt
    both_setup
    FileUtils.mkdir_p(outdir)
    File.write(outdir('old.md'), "old\n")
    git('add', "#{OUT_REL}/old.md")
    git('commit', '-q', '-m', 'old')
    File.write(outdir('old.md'), "edited\n")
    File.write(outdir('discussion.txt'), "thread\n")
    assert run_topic, output
    assert_equal [%w[discovery codex], %w[review claude]], phase_agents
    refute File.exist?(outdir('codex', 'discussion.txt'))
    refute usage.key?('discovery_dirty')
  end

  def test_both_dirt_recorded_once_per_discovery
    both_setup
    FileUtils.mkdir_p(outdir)
    File.write(outdir('discussion.txt'), "thread\n")
    stray = "#{OUT_REL}/00-overview.md"
    msg = "discovery wrote outside #{OUT_REL}/codex: #{stray}"
    both_plan('discovery' => { 'write' => ['02-code-review.md'], 'files' => { File.join(@ws, stray) => 'x' } })
    refute run_topic
    assert_includes output, msg
    assert_equal ["#{OUT_REL}/discussion.txt"], usage['discovery_dirty']

    both_plan
    refute run_topic
    assert_includes output, "FAILED: phase discovery: #{msg}"

    FileUtils.rm_f(File.join(@ws, stray))
    assert run_topic, output
    assert_equal %w[discovery discovery discovery review], calls.map { |c| c['phase'] }
    refute usage.key?('discovery_dirty')
  end

  def test_both_replay_discovery_gets_discussion
    both_setup
    FileUtils.mkdir_p(outdir)
    File.write(outdir('discussion.txt'), "thread\n")
    copy = outdir('codex', 'discussion.txt')
    r = runner(replay: true)
    seen = []
    r.define_singleton_method(:run_session) do |rv, phase, prompt, log, usage|
      seen << [phase.name, File.exist?(copy) && File.read(copy)]
      super(rv, phase, prompt, log, usage)
    end
    ok = nil
    capture_io { ok = r.run_topic(project: 'p', topic: 't1') }
    assert ok, output
    assert_equal [['discovery', "thread\n"], ['review', "thread\n"]], seen
    assert calls.first['replay_note']
    assert_includes git('ls-files', "#{OUT_REL}/codex"), "#{OUT_REL}/codex/discussion.txt"
    assert_equal '', dirty("#{OUT_REL}/codex")
  end

  def test_both_replay_long_limited_discovery_skips
    both_setup
    FileUtils.mkdir_p(outdir)
    File.write(outdir('discussion.txt'), "thread\n")
    ReviewRun::Pause.for(@state, 'codex').set(NOW + (3 * 86_400), by: 'other')
    assert run_topic(replay: true, clock: -> { NOW }), output
    assert_equal [%w[review claude]], phase_agents
    refute File.exist?(outdir('codex'))
  end
end
