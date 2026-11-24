require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'

require_relative '../../lib/review_replay/compare'

class CompareTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CLI = File.join(ROOT, 'bin', 'review-compare')
  FAKE = File.join(ROOT, 'test', 'fixtures', 'review_run', 'fake-claude')

  VALID = {
    'matched' => [{ 'replay' => 'Lost row after NaN', 'reference' => 'GiST misses rows', 'reason' => 'same bug' }],
    'only_reference' => [],
    'only_replay' => [{ 'point' => 'Missing doc update', 'level' => 'POST-MINOR', 'reason' => 'B has it as FYI' }]
  }.freeze

  def setup
    @root = File.realpath(Dir.mktmpdir)
    @replay_root = File.join(@root, 'replay')
    @ref = File.join(@root, 'ref')
    FileUtils.mkdir_p(@ref)
    File.write(File.join(@ref, '05-summary.md'), "ref summary\n")
    @run = make_run('v2-full-1', usage: [1.5, 2.0])
    @calls_file = File.join(@root, 'calls.jsonl')
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def make_run(name, usage: nil, **meta)
    dir = File.join(@replay_root, 'p', 't1', name)
    findings = File.join(dir, 'ws', 'p', 'findings', 't1', 'v2')
    FileUtils.mkdir_p([findings, File.join(dir, 'state')])
    File.write(File.join(findings, '05-summary.md'), "summary #{name}\n")
    File.write(File.join(dir, 'replay.json'),
               JSON.generate({ 'project' => 'p', 'topic' => 't1', 'version' => 2, 'reference' => @ref }
                               .merge(meta.transform_keys(&:to_s))))
    File.symlink('ws/p/findings/t1/v2', File.join(dir, 'findings'))
    if usage
      phases = usage.each_with_index.map do |c, i|
        { 'phase' => "ph#{i}", 'model' => 'opus', 'status' => 'ok', 'cost_usd' => c,
          'tokens' => { 'input' => 1, 'output' => 2, 'cache_read' => 3, 'cache_write' => 4 } }
      end
      File.write(File.join(findings, 'usage.json'), JSON.generate('schema' => 1, 'route' => 'full', 'phases' => phases))
    end
    dir
  end

  def plan(compare_step)
    path = File.join(@root, 'plan.json')
    File.write(path, JSON.generate('compare' => compare_step))
    path
  end

  def fake_writes(label: 'reference', json: JSON.generate(VALID), run: @run)
    plan('files' => { File.join(run, "compare-#{label}.json") => json,
                      File.join(run, "compare-#{label}.md") => "# report\n" })
  end

  def cli(*args, plan_path: nil)
    env = { 'CLAUDE_BIN' => FAKE, 'FAKE_CLAUDE_CALLS' => @calls_file, 'FAKE_CLAUDE_PLAN' => plan_path,
            'REPLAY_DIR' => @replay_root, 'TMUX' => nil, 'ANTHROPIC_API_KEY' => nil }
    Open3.capture2e(env, CLI, *args, chdir: @root)
  end

  def test_resolve_run_and_findings_dirs
    side = ReviewReplay::Compare.resolve(@run)
    assert_equal 'v2-full-1', side.label
    assert_equal @run, side.run_dir
    assert_equal File.join(@run, 'ws', 'p', 'findings', 't1', 'v2'), side.findings_dir
    ref = ReviewReplay::Compare.resolve(@ref)
    assert_equal 'reference', ref.label
    assert_nil ref.run_dir
    assert_equal @ref, ref.findings_dir
  end

  def test_resolve_rejects_dir_without_summary
    e = assert_raises(ReviewReplay::ReplayError) { ReviewReplay::Compare.resolve(@root) }
    assert_equal "#{@root}: not a replay run or a finished review", e.message
  end

  def test_usage_totals_sums_phases
    t = ReviewReplay::Compare.usage_totals(ReviewReplay::Compare.resolve(@run).findings_dir)
    assert_in_delta 3.5, t['cost_usd']
    assert_equal({ 'input' => 2, 'output' => 4, 'cache_read' => 6, 'cache_write' => 8 }, t['tokens'])
    assert_equal [{ 'phase' => 'ph0', 'model' => 'opus', 'status' => 'ok', 'cost_usd' => 1.5 },
                  { 'phase' => 'ph1', 'model' => 'opus', 'status' => 'ok', 'cost_usd' => 2.0 }], t['phases']
  end

  def test_usage_totals_cost_nil_without_numeric_cost
    run = make_run('v2-full-2', usage: [nil, nil])
    t = ReviewReplay::Compare.usage_totals(ReviewReplay::Compare.resolve(run).findings_dir)
    assert_nil t['cost_usd']
  end

  def test_usage_totals_nil_without_usage
    assert_nil ReviewReplay::Compare.usage_totals(@ref)
  end

  def test_prompt_has_paths_and_phase
    text = ReviewReplay::Compare.prompt(replay: '/r/findings', reference: '/ref', md: '/r/c.md', json: '/r/c.json')
    assert text.start_with?("Phase: compare\n"), text[0, 40]
    ["Review A (replay): /r/findings\n", "Review B (reference): /ref\n", "Write /r/c.json:\n", "Write /r/c.md: "].each do |s|
      assert_includes text, s
    end
    refute_match(/\$(REPLAY|REFERENCE|MD|JSON)/, text)
  end

  def test_check_reports_missing_keys
    assert_empty ReviewReplay::Compare.check(VALID)
    errs = ReviewReplay::Compare.check('matched' => [{ 'replay' => 'x' }], 'only_reference' => 'no')
    assert_includes errs, 'matched[0]: missing reference, reason'
    assert_includes errs, 'only_reference: not a list'
    assert_includes errs, 'only_replay: not a list'
  end

  def test_compare_writes_md_and_json
    out, st = cli(@run, @ref, plan_path: fake_writes)
    assert st.success?, out
    data = JSON.parse(File.read(File.join(@run, 'compare-reference.json')))
    assert_equal({ 'matched' => 1, 'only_reference' => 0, 'only_replay' => 1 }, data['counts'])
    assert_in_delta 3.5, data.dig('usage', 'replay', 'cost_usd')
    assert data['usage'].key?('reference')
    assert_nil data.dig('usage', 'reference')
    assert_in_delta 0.5, data['compare_cost_usd']
    assert_equal VALID['matched'], data['matched']
    assert_equal "# report\n", File.read(File.join(@run, 'compare-reference.md'))
    assert_includes out, "matched 1, only in reference 0, only in replay 1\n"
    assert_includes out, "cost replay $3.50 vs reference n/a\n"
    call = JSON.parse(File.readlines(@calls_file).last)
    assert_equal 'compare', call['phase']
    assert_equal @run, File.realpath(call['cwd'])
    assert_includes call['argv'], 'opus'
    refute_includes call['argv'], '--effort'
    assert File.file?(File.join(@run, 'state', 'logs', 'compare-reference.jsonl'))
  end

  def test_bad_json_fails
    out, st = cli(@run, @ref, plan_path: fake_writes(json: 'not json'))
    refute st.success?
    assert_includes out, "ERROR: #{File.join(@run, 'compare-reference.json')}: invalid ("
    assert File.file?(File.join(@run, 'compare-reference.md'))
  end

  def test_missing_json_fails
    File.write(File.join(@run, 'compare-reference.json'), JSON.generate(VALID))
    out, st = cli(@run, @ref, plan_path: plan({}))
    refute st.success?
    assert_includes out, "ERROR: #{File.join(@run, 'compare-reference.json')}: invalid (missing)"
  end

  def test_first_arg_must_be_run
    out, st = cli(@ref, @run, plan_path: fake_writes)
    refute st.success?
    assert_includes out, "ERROR: #{@ref}: not a replay run"
  end

  def test_reference_run_dir_label
    other = make_run('v2-single-1', usage: [1.0])
    out, st = cli(@run, other, plan_path: fake_writes(label: 'v2-single-1'))
    assert st.success?, out
    data = JSON.parse(File.read(File.join(@run, 'compare-v2-single-1.json')))
    assert_in_delta 1.0, data.dig('usage', 'reference', 'cost_usd')
    assert_includes out, "cost replay $3.50 vs reference $1.00\n"
  end

  def test_refuses_replay_without_summary
    File.delete(File.join(@run, 'findings', '05-summary.md'))
    out, st = cli(@run, @ref, plan_path: fake_writes)
    refute st.success?
    assert_includes out, "ERROR: #{@run}: replay has no 05-summary.md"
    refute File.exist?(@calls_file)
  end

  def test_refuses_wrong_reference
    other = File.join(@root, 'other')
    FileUtils.mkdir_p(other)
    File.write(File.join(other, '05-summary.md'), "other\n")
    out, st = cli(@run, other, plan_path: fake_writes)
    refute st.success?
    assert_includes out, "ERROR: #{other} is not the reference of #{@run} (#{@ref})"
    refute File.exist?(@calls_file)
  end

  def test_refuses_run_of_other_version
    other = make_run('v3-single-1', version: 3)
    out, st = cli(@run, other, plan_path: fake_writes(label: 'v3-single-1'))
    refute st.success?
    assert_includes out, "ERROR: #{other} replays p/t1 v3, #{@run} replays p/t1 v2"
    refute File.exist?(@calls_file)
  end

  def test_table_flags_failed_changed_and_invalid
    bad = make_run('v2-full-2', usage: [1.0], ok: false, inputs_changed: true)
    assert cli(bad, @ref, plan_path: fake_writes(run: bad)).last.success?
    File.write(File.join(@run, 'compare-reference.json'), JSON.generate(VALID))
    out, st = cli('--table')
    assert st.success?, out
    assert_equal ["p/t1 v2-full-1 vs reference: invalid compare (no counts)\n",
                  "p/t1 v2-full-2 vs reference: matched 1, only-ref 0, only-replay 1, cost $1.00 vs n/a " \
                  "[replay failed] [inputs changed]\n"],
                 out.lines
  end

  def test_table_lists_compares
    other = make_run('v2-single-1', usage: [1.0])
    assert cli(@run, @ref, plan_path: fake_writes).last.success?
    assert cli(other, @ref, plan_path: fake_writes(run: other)).last.success?
    out, st = cli('--table')
    assert st.success?, out
    assert_equal ["p/t1 v2-full-1 vs reference: matched 1, only-ref 0, only-replay 1, cost $3.50 vs n/a\n",
                  "p/t1 v2-single-1 vs reference: matched 1, only-ref 0, only-replay 1, cost $1.00 vs n/a\n"],
                 out.lines
  end
end
