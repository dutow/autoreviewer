require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

load File.expand_path('../bin/review-poll', __dir__)

class ReviewPollCoreTest < Minitest::Test
  def with_poller
    Dir.mktmpdir do |dir|
      ENV['REVIEW_POLL_STATE'] = File.join(dir, '.review-poll.state')
      ENV['WORKSPACE_DIR'] = dir
      yield ReviewPoll.new(base_dir: dir), dir
    ensure
      ENV.delete('REVIEW_POLL_STATE')
      ENV.delete('WORKSPACE_DIR')
    end
  end

  def write_project(dir, name, contents)
    pdir = File.join(dir, name)
    FileUtils.mkdir_p(pdir)
    File.write(File.join(pdir, 'project.yaml'), contents)
  end

  def test_plan_baseline_when_prev_nil
    with_poller do |poller, _|
      result = poller.plan(nil, [{ topic: 'pr1', head: 'aaa' }])
      assert result[:baseline]
      assert_empty result[:decisions]
    end
  end

  def test_plan_classifies_changed_unchanged_and_new
    with_poller do |poller, _|
      prev = { 'pr1' => 'aaa', 'pr2' => 'bbb' }
      prs = [
        { topic: 'pr1', head: 'aaa' },   # unchanged
        { topic: 'pr2', head: 'ZZZ' },   # changed
        { topic: 'pr3', head: 'ccc' },   # new (absent from prev)
      ]
      result = poller.plan(prev, prs)
      refute result[:baseline]
      by_topic = result[:decisions].to_h { |d| [d[:topic], d[:status]] }
      assert_equal :unchanged, by_topic['pr1']
      assert_equal :changed,   by_topic['pr2']
      assert_equal :changed,   by_topic['pr3']
    end
  end

  def test_state_round_trip_and_missing_file
    with_poller do |poller, _|
      assert_equal({}, poller.state)
      poller.state['psp'] = { 'pr1' => 'aaa' }
      poller.save_state
      reloaded = ReviewPoll.new(base_dir: poller.base_dir)
      assert_equal({ 'psp' => { 'pr1' => 'aaa' } }, reloaded.state)
    end
  end

  def test_corrupt_state_starts_fresh
    with_poller do |poller, _|
      File.write(ENV['REVIEW_POLL_STATE'], 'not json{')
      assert_equal({}, ReviewPoll.new(base_dir: poller.base_dir).state)
    end
  end

  def test_enabled_projects_filters_by_flag_and_base_branch
    with_poller do |poller, dir|
      write_project(dir, 'gh',    "name: gh\nsource: o/gh\nbase_branch: main\ntopic_prefix: pr\npoll:\n  enabled: true\n")
      write_project(dir, 'pglike', "name: pglike\nbase_branch: master\npoll:\n  enabled: true\n")
      write_project(dir, 'off',   "name: off\nsource: o/off\nbase_branch: main\npoll:\n  enabled: false\n")
      write_project(dir, 'nobase', "name: nobase\nsource: o/nobase\npoll:\n  enabled: true\n")
      write_project(dir, 'plain', "name: plain\nsource: o/plain\nbase_branch: main\n")

      by_name = poller.enabled_projects.to_h { |p| [p[:name], p] }
      assert_equal %w[gh pglike], by_name.keys.sort

      assert_equal 'o/gh', by_name['gh'][:source]
      assert_equal 'main', by_name['gh'][:base_branch]
      assert_equal 'pr',   by_name['gh'][:prefix]
      assert_equal File.join(dir, 'gh', 'master'), by_name['gh'][:master_dir]

      assert_nil by_name['pglike'][:source]
      assert_equal 'master', by_name['pglike'][:base_branch]
    end
  end

  def test_open_prs_parses_base_and_requests_baseRefName
    with_poller do |poller, dir|
      bin = File.join(dir, 'fakebin')
      FileUtils.mkdir_p(bin)
      log = File.join(dir, 'gh-args.log')
      File.write(File.join(bin, 'gh'), <<~SH)
        #!/usr/bin/env bash
        echo "$@" > #{log}
        echo '[{"number":7,"headRefOid":"aaa","baseRefName":"main","isDraft":false},{"number":8,"headRefOid":"bbb","baseRefName":"main","isDraft":true}]'
      SH
      FileUtils.chmod(0o755, File.join(bin, 'gh'))
      old = ENV['PATH']
      ENV['PATH'] = "#{bin}:#{old}"
      begin
        prs = poller.open_prs('o/repo')
        assert_equal [{ number: 7, head: 'aaa', base: 'main', draft: false },
                      { number: 8, head: 'bbb', base: 'main', draft: true }], prs
        assert_includes File.read(log), 'number,headRefOid,baseRefName,isDraft'
      ensure
        ENV['PATH'] = old
      end
    end
  end
end

class ReviewPollRunOnceTest < Minitest::Test
  def with_poller
    Dir.mktmpdir do |dir|
      ENV['REVIEW_POLL_STATE'] = File.join(dir, '.review-poll.state')
      ENV['WORKSPACE_DIR'] = dir
      yield ReviewPoll.new(base_dir: dir)
    ensure
      ENV.delete('REVIEW_POLL_STATE')
      ENV.delete('WORKSPACE_DIR')
    end
  end

  PROJ = [{ name: 'psp', source: 'o/psp', prefix: 'pr',
            base_branch: 'main', master_dir: '/tmp/psp/master' }].freeze

  def fetch_returning(prs)
    ->(_source) { prs }
  end

  def recording_enqueue(log, fail: [])
    ->(project, topic) { log << [project, topic]; !fail.include?(topic) }
  end

  def recording_refresh(log)
    ->(proj, bases) { log << [proj[:name], bases] }
  end

  def test_first_cycle_baselines_without_enqueue
    with_poller do |poller|
      calls = []
      refreshed = []
      poller.run_once(projects: PROJ,
                      fetch: fetch_returning([{ number: 1, head: 'aaa', base: 'main' }]),
                      enqueue: recording_enqueue(calls),
                      refresh: recording_refresh(refreshed))
      assert_empty calls
      assert_equal [['psp', ['main']]], refreshed
      assert_equal({ 'pr1' => 'aaa' }, poller.state['psp'])
    end
  end

  def test_second_cycle_enqueues_changed_and_new_only
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa', 'pr2' => 'bbb' }
      calls = []
      poller.run_once(
        projects: PROJ,
        fetch: fetch_returning([
          { number: 1, head: 'aaa' },   # unchanged
          { number: 2, head: 'ZZZ' },   # changed
          { number: 3, head: 'ccc' },   # new
        ]),
        enqueue: recording_enqueue(calls),
        refresh: recording_refresh([])
      )
      assert_equal [['psp', 'pr2'], ['psp', 'pr3']], calls.sort
      assert_equal({ 'pr1' => 'aaa', 'pr2' => 'ZZZ', 'pr3' => 'ccc' }, poller.state['psp'])
    end
  end

  def test_only_reviewed_enqueues_changed_prs_with_findings_only
    with_poller do |poller|
      dir = poller.base_dir
      FileUtils.mkdir_p(File.join(dir, 'psp', 'findings', 'pr2'))
      proj = [PROJ.first.merge(findings_dir: File.join(dir, 'psp', 'findings'), only_reviewed: true)]
      poller.state['psp'] = { 'pr1' => 'aaa', 'pr2' => 'bbb' }
      calls = []
      poller.run_once(
        projects: proj,
        fetch: fetch_returning([
          { number: 1, head: 'AAA' },   # changed, never reviewed
          { number: 2, head: 'BBB' },   # changed, reviewed
          { number: 3, head: 'ccc' },   # new
        ]),
        enqueue: recording_enqueue(calls),
        refresh: recording_refresh([])
      )
      assert_equal [['psp', 'pr2']], calls
      assert_equal({ 'pr1' => 'AAA', 'pr2' => 'BBB', 'pr3' => 'ccc' }, poller.state['psp'])
    end
  end

  def test_closed_pr_drops_from_state
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa', 'pr2' => 'bbb' }
      poller.run_once(projects: PROJ,
                      fetch: fetch_returning([{ number: 1, head: 'aaa' }]),
                      enqueue: recording_enqueue([]),
                      refresh: recording_refresh([]))
      assert_equal({ 'pr1' => 'aaa' }, poller.state['psp'])
    end
  end

  def test_skip_drafts_untracked_until_ready
    with_poller do |poller|
      proj = [PROJ.first.merge(skip_drafts: true)]
      poller.state['psp'] = { 'pr1' => 'aaa' }
      calls = []
      out, = capture_io do
        2.times do # second cycle: same drafts, logged once
          poller.run_once(projects: proj,
                          fetch: fetch_returning([{ number: 1, head: 'aaa', draft: true },   # tracked, now draft
                                                  { number: 2, head: 'bbb', draft: true }]), # new draft
                          enqueue: recording_enqueue(calls), refresh: recording_refresh([]))
        end
      end
      assert_empty calls
      assert_equal({ 'drafts' => { 'pr1' => 'aaa', 'pr2' => 'bbb' } }, poller.state['psp'])
      assert_equal 1, out.scan('pr2 draft bbb, skipped (skip_drafts)').size

      # pr2 marked ready for review without a new push: polled as new
      poller.run_once(projects: proj,
                      fetch: fetch_returning([{ number: 1, head: 'aaa', draft: true },
                                              { number: 2, head: 'bbb', draft: false }]),
                      enqueue: recording_enqueue(calls), refresh: recording_refresh([]))
      assert_equal [['psp', 'pr2']], calls
      assert_equal({ 'pr2' => 'bbb', 'drafts' => { 'pr1' => 'aaa' } }, poller.state['psp'])
    end
  end

  def test_drafts_polled_without_skip_drafts
    with_poller do |poller|
      poller.state['psp'] = {}
      calls = []
      poller.run_once(projects: PROJ,
                      fetch: fetch_returning([{ number: 2, head: 'bbb', draft: true }]),
                      enqueue: recording_enqueue(calls), refresh: recording_refresh([]))
      assert_equal [['psp', 'pr2']], calls
      assert_equal({ 'pr2' => 'bbb' }, poller.state['psp'])
    end
  end

  def test_skip_drafts_baseline_leaves_drafts_untracked
    with_poller do |poller|
      calls = []
      poller.run_once(projects: [PROJ.first.merge(skip_drafts: true)],
                      fetch: fetch_returning([{ number: 1, head: 'aaa', draft: false },
                                              { number: 2, head: 'bbb', draft: true }]),
                      enqueue: recording_enqueue(calls), refresh: recording_refresh([]))
      assert_empty calls
      assert_equal({ 'pr1' => 'aaa', 'drafts' => { 'pr2' => 'bbb' } }, poller.state['psp'])
    end
  end

  def test_failed_enqueue_not_recorded
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa' }
      calls = []
      poller.run_once(projects: PROJ,
                      fetch: fetch_returning([{ number: 2, head: 'bbb' }]),
                      enqueue: recording_enqueue(calls, fail: ['pr2']),
                      refresh: recording_refresh([]))
      assert_equal [['psp', 'pr2']], calls
      refute poller.state['psp'].key?('pr2')
    end
  end

  def test_fetch_failure_leaves_state_untouched
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa' }
      poller.run_once(projects: PROJ,
                      fetch: ->(_s) { nil },
                      enqueue: recording_enqueue([]),
                      refresh: recording_refresh([]))
      assert_equal({ 'pr1' => 'aaa' }, poller.state['psp'])
    end
  end

  def test_gh_bases_are_distinct_baserefs_union_base_branch
    with_poller do |poller|
      refreshed = []
      poller.run_once(
        projects: PROJ,
        fetch: fetch_returning([
          { number: 1, head: 'aaa', base: 'main' },
          { number: 2, head: 'bbb', base: 'rel-18' },
          { number: 3, head: 'ccc', base: 'main' },
        ]),
        enqueue: recording_enqueue([]),
        refresh: ->(proj, bases) { refreshed << [proj[:name], bases.sort] }
      )
      assert_equal [['psp', %w[main rel-18]]], refreshed
    end
  end

  def test_source_less_project_refreshes_only
    with_poller do |poller|
      only = [{ name: 'postgres', source: nil, prefix: 't',
                base_branch: 'master', master_dir: '/tmp/pg/master' }]
      fetched = []
      enq = []
      refreshed = []
      poller.run_once(
        projects: only,
        fetch: ->(s) { fetched << s; [] },
        enqueue: recording_enqueue(enq),
        refresh: recording_refresh(refreshed)
      )
      assert_empty fetched
      assert_empty enq
      assert_equal [['postgres', ['master']]], refreshed
      assert_nil poller.state['postgres']
    end
  end
end

class ReviewPollDebounceTest < Minitest::Test
  T0 = Time.utc(2026, 11, 20, 10, 0, 0)
  PROJ_D = [{ name: 'psp', source: 'o/psp', prefix: 'pr', base_branch: 'main',
              master_dir: '/tmp/psp/master', debounce_minutes: 120 }].freeze

  def with_poller
    Dir.mktmpdir do |dir|
      ENV['REVIEW_POLL_STATE'] = File.join(dir, '.review-poll.state')
      ENV['WORKSPACE_DIR'] = dir
      yield ReviewPoll.new(base_dir: dir)
    ensure
      ENV.delete('REVIEW_POLL_STATE')
      ENV.delete('WORKSPACE_DIR')
    end
  end

  def cycle(poller, prs, at, calls, projects: PROJ_D, fail: [])
    poller.run_once(projects: projects,
                    fetch: ->(_s) { prs },
                    enqueue: ->(p, t) { calls << [p, t]; !fail.include?(t) },
                    refresh: ->(_p, _b) {},
                    now: at)
  end

  def mins(n) = T0 + n * 60

  def test_debounce_ready_zero_minutes_is_ready_and_drops_entry
    with_poller do |p|
      ready, pending = p.debounce_ready?({ 'pr1' => { 'head' => 'a', 'seen_at' => T0.iso8601 } }, 'pr1', 'b', T0, 0)
      assert ready
      assert_equal({}, pending)
    end
  end

  def test_debounce_ready_new_or_changed_head_starts_wait
    with_poller do |p|
      ready, pending = p.debounce_ready?({}, 'pr1', 'a', T0, 120)
      refute ready
      assert_equal({ 'pr1' => { 'head' => 'a', 'seen_at' => T0.iso8601 } }, pending)
      ready, pending = p.debounce_ready?(pending, 'pr1', 'b', mins(30), 120)
      refute ready
      assert_equal({ 'pr1' => { 'head' => 'b', 'seen_at' => mins(30).iso8601 } }, pending)
    end
  end

  def test_debounce_ready_same_head_after_quiet_period
    with_poller do |p|
      start = { 'pr1' => { 'head' => 'a', 'seen_at' => T0.iso8601 } }
      ready, pending = p.debounce_ready?(start, 'pr1', 'a', mins(120), 120)
      assert ready
      assert_equal({}, pending)
    end
  end

  def test_debounce_ready_same_head_still_waiting
    with_poller do |p|
      start = { 'pr1' => { 'head' => 'a', 'seen_at' => T0.iso8601 } }
      ready, pending = p.debounce_ready?(start, 'pr1', 'a', mins(119), 120)
      refute ready
      assert_equal(start, pending)
    end
  end

  def test_debounce_waits_before_enqueue
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa' }
      calls = []
      prs = [{ number: 1, head: 'bbb' }]
      cycle(poller, prs, T0, calls)
      assert_empty calls
      assert_equal 'aaa', poller.state['psp']['pr1']
      assert_equal({ 'pr1' => { 'head' => 'bbb', 'seen_at' => T0.iso8601 } }, poller.state['psp']['debounce'])
      cycle(poller, prs, mins(119), calls)
      assert_empty calls
      cycle(poller, prs, mins(120), calls)
      assert_equal [['psp', 'pr1']], calls
      assert_equal({ 'pr1' => 'bbb' }, poller.state['psp'])
    end
  end

  def test_debounce_newer_push_restarts_wait
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa' }
      calls = []
      cycle(poller, [{ number: 1, head: 'AAA' }], T0, calls)
      cycle(poller, [{ number: 1, head: 'BBB' }], mins(60), calls)
      cycle(poller, [{ number: 1, head: 'BBB' }], mins(120), calls)
      assert_empty calls
      cycle(poller, [{ number: 1, head: 'BBB' }], mins(180), calls)
      assert_equal [['psp', 'pr1']], calls
      assert_equal 'BBB', poller.state['psp']['pr1']
    end
  end

  def test_debounce_zero_enqueues_immediately
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa' }
      calls = []
      cycle(poller, [{ number: 1, head: 'bbb' }], T0, calls,
            projects: [PROJ_D.first.merge(debounce_minutes: 0)])
      assert_equal [['psp', 'pr1']], calls
      assert_equal({ 'pr1' => 'bbb' }, poller.state['psp'])
    end
  end

  def test_debounce_new_pr_waits_too
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa' }
      calls = []
      prs = [{ number: 1, head: 'aaa' }, { number: 2, head: 'ccc' }]
      cycle(poller, prs, T0, calls)
      assert_empty calls
      refute poller.state['psp'].key?('pr2')
      cycle(poller, prs, mins(120), calls)
      assert_equal [['psp', 'pr2']], calls
    end
  end

  def test_debounce_closed_pr_dropped
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa', 'pr2' => 'bbb' }
      calls = []
      cycle(poller, [{ number: 1, head: 'aaa' }, { number: 2, head: 'BBB' }], T0, calls)
      assert poller.state['psp']['debounce'].key?('pr2')
      cycle(poller, [{ number: 1, head: 'aaa' }], mins(120), calls)
      assert_empty calls
      assert_equal({ 'pr1' => 'aaa' }, poller.state['psp'])
    end
  end

  def test_debounce_old_state_without_key
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa', 'hackorum' => { 'cursor' => 'x' } }
      calls = []
      cycle(poller, [{ number: 1, head: 'bbb' }], T0, calls)
      assert_empty calls
      assert_equal 'bbb', poller.state['psp']['debounce']['pr1']['head']
      assert_equal({ 'cursor' => 'x' }, poller.state['psp']['hackorum'])
    end
  end

  def test_debounce_only_reviewed_unreviewed_skips_without_wait
    with_poller do |poller|
      dir = poller.base_dir
      proj = [PROJ_D.first.merge(findings_dir: File.join(dir, 'psp', 'findings'), only_reviewed: true)]
      poller.state['psp'] = { 'pr1' => 'aaa' }
      calls = []
      cycle(poller, [{ number: 1, head: 'bbb' }], T0, calls, projects: proj)
      assert_empty calls
      assert_equal({ 'pr1' => 'bbb' }, poller.state['psp'])
    end
  end

  def test_debounce_enqueue_failure_retries
    with_poller do |poller|
      poller.state['psp'] = { 'pr1' => 'aaa' }
      calls = []
      prs = [{ number: 1, head: 'bbb' }]
      cycle(poller, prs, T0, calls)
      cycle(poller, prs, mins(120), calls, fail: ['pr1'])
      assert_equal [['psp', 'pr1']], calls
      assert_equal 'aaa', poller.state['psp']['pr1']
      assert poller.state['psp']['debounce'].key?('pr1')
      cycle(poller, prs, mins(123), calls)
      assert_equal [['psp', 'pr1'], ['psp', 'pr1']], calls
      assert_equal({ 'pr1' => 'bbb' }, poller.state['psp'])
    end
  end

  def test_debounce_baseline_creates_no_entries
    with_poller do |poller|
      calls = []
      cycle(poller, [{ number: 1, head: 'aaa' }], T0, calls)
      assert_empty calls
      assert_equal({ 'pr1' => 'aaa' }, poller.state['psp'])
    end
  end

  def test_debounce_ready_malformed_entry_restarts_wait
    with_poller do |p|
      [5, ['x'], { 'head' => 'a' }, { 'head' => 'a', 'seen_at' => 'garbage' }].each do |bad|
        ready, pending = p.debounce_ready?({ 'pr1' => bad }, 'pr1', 'a', T0, 120)
        refute ready
        assert_equal({ 'pr1' => { 'head' => 'a', 'seen_at' => T0.iso8601 } }, pending)
      end
    end
  end

  def test_debounce_manual_enqueue_during_wait_not_duplicated
    with_poller do |poller|
      dir = poller.base_dir
      FileUtils.mkdir_p(File.join(dir, 'state'))
      File.write(File.join(dir, 'state', 'queue'), "psp pr9\npsp pr1\n")
      File.write(File.join(dir, 'state', 'queue.processed'), "0\n")
      poller.state['psp'] = { 'pr1' => 'aaa' }
      calls = []
      prs = [{ number: 1, head: 'bbb' }]
      cycle(poller, prs, T0, calls)
      cycle(poller, prs, mins(120), calls)
      assert_empty calls
      assert_equal({ 'pr1' => 'bbb' }, poller.state['psp'])
    end
  end

  def test_debounce_head_already_reviewed_not_duplicated
    with_poller do |poller|
      dir = poller.base_dir
      rdir = File.join(dir, 'psp', 'review', 'pr1')
      FileUtils.mkdir_p(rdir)
      File.write(File.join(rdir, 'metadata.json'), JSON.generate('topic' => 'pr1', 'head_sha' => 'bbb'))
      proj = [PROJ_D.first.merge(findings_dir: File.join(dir, 'psp', 'findings'))]
      poller.state['psp'] = { 'pr1' => 'aaa' }
      calls = []
      prs = [{ number: 1, head: 'bbb' }]
      cycle(poller, prs, T0, calls, projects: proj)
      cycle(poller, prs, mins(120), calls, projects: proj)
      assert_empty calls
      assert_equal({ 'pr1' => 'bbb' }, poller.state['psp'])
    end
  end

  def test_enabled_projects_debounce_minutes
    with_poller do |poller|
      dir = poller.base_dir
      { 'a' => '', 'b' => "  debounce_minutes: 0\n", 'c' => "  debounce_minutes: -5\n", 'd' => "  debounce_minutes: 30\n" }.each do |name, extra|
        FileUtils.mkdir_p(File.join(dir, name))
        File.write(File.join(dir, name, 'project.yaml'),
                   "name: #{name}\nbase_branch: main\nsource: o/#{name}\npoll:\n  enabled: true\n#{extra}")
      end
      got = poller.send(:enabled_projects).to_h { |p| [p[:name], p[:debounce_minutes]] }
      assert_equal({ 'a' => 120, 'b' => 0, 'c' => 0, 'd' => 30 }, got)
    end
  end

  def test_enabled_projects_skip_drafts
    with_poller do |poller|
      dir = poller.base_dir
      { 'a' => '', 'b' => "  skip_drafts: true\n", 'c' => "  skip_drafts: yes-ish\n" }.each do |name, extra|
        FileUtils.mkdir_p(File.join(dir, name))
        File.write(File.join(dir, name, 'project.yaml'),
                   "name: #{name}\nbase_branch: main\nsource: o/#{name}\npoll:\n  enabled: true\n#{extra}")
      end
      got = poller.send(:enabled_projects).to_h { |p| [p[:name], p[:skip_drafts]] }
      assert_equal({ 'a' => false, 'b' => true, 'c' => false }, got)
    end
  end
end

class ReviewPollRefreshTest < Minitest::Test
  def sh(dir, *args)
    system('git', '-C', dir, *args, out: File::NULL, err: File::NULL) or
      raise "git #{args.join(' ')} failed in #{dir}"
  end

  def make_origin(dir)
    origin = File.join(dir, 'origin')
    FileUtils.mkdir_p(origin)
    sh(origin, 'init', '-q', '-b', 'master')
    sh(origin, 'config', 'user.email', 't@t')
    sh(origin, 'config', 'user.name', 't')
    File.write(File.join(origin, 'f'), "v1\n")
    sh(origin, 'add', 'f')
    sh(origin, 'commit', '-q', '-m', 'v1')
    origin
  end

  def poller(dir)
    ENV['REVIEW_POLL_STATE'] = File.join(dir, '.review-poll.state')
    ENV['WORKSPACE_DIR'] = dir
    ReviewPoll.new(base_dir: dir)
  ensure
    ENV.delete('REVIEW_POLL_STATE')
    ENV.delete('WORKSPACE_DIR')
  end

  def head_file(dir)
    File.read(File.join(dir, 'f'))
  end

  def test_reset_hard_when_base_checked_out
    Dir.mktmpdir do |dir|
      origin = make_origin(dir)
      master = File.join(dir, 'master')
      sh(dir, 'clone', '-q', origin, master)
      File.write(File.join(origin, 'f'), "v2\n")
      sh(origin, 'commit', '-aqm', 'v2')
      File.write(File.join(master, 'f'), "dirty\n")

      poller(dir).refresh_one(master, 'master')

      assert_equal "v2\n", head_file(master)
    end
  end

  def test_branch_f_when_detached
    Dir.mktmpdir do |dir|
      origin = make_origin(dir)
      master = File.join(dir, 'master')
      sh(dir, 'clone', '-q', origin, master)
      first = `git -C #{master} rev-parse master`.strip
      sh(master, 'checkout', '-q', '--detach', first)
      File.write(File.join(origin, 'f'), "v2\n")
      sh(origin, 'commit', '-aqm', 'v2')

      poller(dir).refresh_one(master, 'master')

      moved = `git -C #{master} rev-parse master`.strip
      refute_equal first, moved
      assert_equal first, `git -C #{master} rev-parse HEAD`.strip
    end
  end

  def test_missing_repo_warns_no_raise
    Dir.mktmpdir do |dir|
      poller(dir).refresh_one(File.join(dir, 'nope'), 'master')
    end
  end

  def test_fetch_failure_warns_no_raise
    Dir.mktmpdir do |dir|
      origin = make_origin(dir)
      master = File.join(dir, 'master')
      sh(dir, 'clone', '-q', origin, master)
      before = `git -C #{master} rev-parse master`.strip
      poller(dir).refresh_one(master, 'nonexistent-branch')
      assert_equal before, `git -C #{master} rev-parse master`.strip
    end
  end

  def test_refresh_bases_dedupes_and_drops_nil
    Dir.mktmpdir do |dir|
      seen = []
      p = poller(dir)
      p.define_singleton_method(:refresh_one) { |md, b| seen << [md, b] }
      p.refresh_bases({ master_dir: '/m' }, ['main', 'main', nil, 'dev'])
      assert_equal [['/m', 'main'], ['/m', 'dev']], seen
    end
  end
end

class ReviewPollCommitPlanTest < Minitest::Test
  def with_poller
    Dir.mktmpdir do |dir|
      ENV['REVIEW_POLL_STATE'] = File.join(dir, '.review-poll.state')
      ENV['WORKSPACE_DIR'] = dir
      yield ReviewPoll.new(base_dir: dir)
    ensure
      ENV.delete('REVIEW_POLL_STATE')
      ENV.delete('WORKSPACE_DIR')
    end
  end

  def test_in_window_normal_range
    with_poller do |p|
      assert p.in_window?(Time.new(2026, 7, 4, 3, 0), '02:00-05:00')
      assert p.in_window?(Time.new(2026, 7, 4, 2, 0), '02:00-05:00')   # start inclusive
      refute p.in_window?(Time.new(2026, 7, 4, 5, 0), '02:00-05:00')   # end exclusive
      refute p.in_window?(Time.new(2026, 7, 4, 1, 59), '02:00-05:00')
    end
  end

  def test_in_window_overnight_range
    with_poller do |p|
      assert p.in_window?(Time.new(2026, 7, 4, 23, 30), '23:00-02:00')
      assert p.in_window?(Time.new(2026, 7, 4, 1, 0), '23:00-02:00')
      refute p.in_window?(Time.new(2026, 7, 4, 12, 0), '23:00-02:00')
    end
  end

  def test_in_window_default_and_garbage
    with_poller do |p|
      assert p.in_window?(Time.new(2026, 7, 4, 3, 0), nil)     # default 02:00-05:00
      assert p.in_window?(Time.new(2026, 7, 4, 3, 0), '')      # blank -> default
      refute p.in_window?(Time.new(2026, 7, 4, 3, 0), 'zzz')   # unparseable -> never
    end
  end

  def test_commit_batch_due
    with_poller do |p|
      in_win  = Time.new(2026, 7, 4, 3, 0)
      out_win = Time.new(2026, 7, 4, 12, 0)
      refute p.commit_batch_due?({}, out_win, nil)
      assert p.commit_batch_due?({}, in_win, nil)                        # never enqueued
      fresh = { 'last_enqueued_at' => (in_win - 3600).utc.iso8601 }
      refute p.commit_batch_due?(fresh, in_win, nil)                     # 1h ago
      old = { 'last_enqueued_at' => (in_win - 21 * 3600).utc.iso8601 }
      assert p.commit_batch_due?(old, in_win, nil)                       # 21h ago
      assert p.commit_batch_due?(fresh, out_win, nil, bypass: true)      # bypass wins
      assert p.commit_batch_due?(nil, in_win, nil)                       # no state at all
      exact = { 'last_enqueued_at' => (in_win - 20 * 3600).utc.iso8601 }
      assert p.commit_batch_due?(exact, in_win, nil)                     # boundary: exactly 20h
      assert p.commit_batch_due?({ 'last_enqueued_at' => 'garbage' }, in_win, nil)
    end
  end

  def test_chunk_commits
    with_poller do |p|
      shas = %w[c1 c2 c3 c4 c5]
      assert_equal [%w[c0 c2], %w[c2 c4], %w[c4 c5]], p.chunk_commits('c0', shas, 2)
      assert_equal [%w[c0 c3], %w[c3 c5]], p.chunk_commits('c0', shas, 3)
      assert_equal [%w[c0 c5]], p.chunk_commits('c0', shas, 10)
      assert_equal [%w[c0 c5]], p.chunk_commits('c0', shas, 0) # bad max_batch -> default (10)
      assert_empty p.chunk_commits('c0', [], 2)
    end
  end
end

class ReviewPollCommitReviewTest < Minitest::Test
  def sh(dir, *args)
    system('git', '-C', dir, *args, out: File::NULL, err: File::NULL) or
      raise "git #{args.join(' ')} failed in #{dir}"
  end

  def make_origin(dir, commits:)
    origin = File.join(dir, 'origin')
    FileUtils.mkdir_p(origin)
    sh(origin, 'init', '-q', '-b', 'master')
    sh(origin, 'config', 'user.email', 't@t')
    sh(origin, 'config', 'user.name', 't')
    commits.times do |i|
      File.write(File.join(origin, 'f'), "v#{i}\n")
      sh(origin, 'add', 'f')
      sh(origin, 'commit', '-q', '-m', "c#{i}")
    end
    origin
  end

  def setup_proj(dir, commits:, max_batch: 2)
    make_origin(dir, commits: commits)
    master = File.join(dir, 'master')
    sh(dir, 'clone', '-q', File.join(dir, 'origin'), master)
    proj = { name: 'pg', source: nil, prefix: 't', base_branch: 'master',
             master_dir: master,
             commit_review: { 'command' => 'pg:review-commits', 'max_batch' => max_batch } }
    [master, proj]
  end

  def poller(dir)
    ENV['REVIEW_POLL_STATE'] = File.join(dir, '.review-poll.state')
    ENV['WORKSPACE_DIR'] = dir
    ReviewPoll.new(base_dir: dir)
  ensure
    ENV.delete('REVIEW_POLL_STATE')
    ENV.delete('WORKSPACE_DIR')
  end

  def rev(dir, ref)
    `git -C #{dir} rev-parse #{ref}`.strip
  end

  IN_WIN = Time.new(2026, 7, 4, 3, 0).freeze
  OUT_WIN = Time.new(2026, 7, 4, 12, 0).freeze

  def test_baseline_short_repo_is_head
    Dir.mktmpdir do |dir|
      master, proj = setup_proj(dir, commits: 3)
      p = poller(dir)
      p.process_commit_reviews(proj, now: IN_WIN,
                               enqueue_commits: ->(*) { flunk 'no enqueue on baseline' })
      assert_equal rev(master, 'origin/master'), p.state['pg']['commit_review']['last_sha']
    end
  end

  def test_baseline_long_repo_is_head_minus_20
    Dir.mktmpdir do |dir|
      master, proj = setup_proj(dir, commits: 25)
      p = poller(dir)
      p.process_commit_reviews(proj, now: IN_WIN,
                               enqueue_commits: ->(*) { flunk 'no enqueue on baseline' })
      assert_equal rev(master, 'origin/master~20'), p.state['pg']['commit_review']['last_sha']
    end
  end

  def test_enqueues_all_chunks_and_advances_marker
    Dir.mktmpdir do |dir|
      master, proj = setup_proj(dir, commits: 6, max_batch: 2)
      p = poller(dir)
      base = rev(master, 'origin/master~5')
      p.state['pg'] = { 'commit_review' => { 'last_sha' => base } }
      calls = []
      p.process_commit_reviews(proj, now: IN_WIN,
                               enqueue_commits: ->(prj, from, to) { calls << [prj, from, to]; true })
      assert_equal 3, calls.size
      assert_equal 'pg', calls.first[0]
      assert_equal base, calls.first[1]
      assert_equal rev(master, 'origin/master'), calls.last[2]
      calls.each_cons(2) { |a, b| assert_equal a[2], b[1] } # consecutive ranges
      cr = p.state['pg']['commit_review']
      assert_equal rev(master, 'origin/master'), cr['last_sha']
      refute_nil cr['last_enqueued_at']
    end
  end

  def test_failed_enqueue_stops_marker_at_last_success
    Dir.mktmpdir do |dir|
      master, proj = setup_proj(dir, commits: 6, max_batch: 2)
      p = poller(dir)
      base = rev(master, 'origin/master~5')
      p.state['pg'] = { 'commit_review' => { 'last_sha' => base } }
      calls = []
      p.process_commit_reviews(proj, now: IN_WIN,
                               enqueue_commits: ->(_prj, from, to) { calls << [from, to]; calls.size < 2 })
      assert_equal 2, calls.size # second failed, third never attempted
      assert_equal calls.first[1], p.state['pg']['commit_review']['last_sha']
    end
  end

  def test_outside_window_no_enqueue
    Dir.mktmpdir do |dir|
      master, proj = setup_proj(dir, commits: 6, max_batch: 2)
      p = poller(dir)
      base = rev(master, 'origin/master~5')
      p.state['pg'] = { 'commit_review' => { 'last_sha' => base } }
      p.process_commit_reviews(proj, now: OUT_WIN,
                               enqueue_commits: ->(*) { flunk 'must not enqueue' })
      assert_equal base, p.state['pg']['commit_review']['last_sha']
    end
  end

  def test_bypass_env_skips_window
    Dir.mktmpdir do |dir|
      master, proj = setup_proj(dir, commits: 6, max_batch: 10)
      p = poller(dir)
      p.state['pg'] = { 'commit_review' => { 'last_sha' => rev(master, 'origin/master~5') } }
      calls = []
      ENV['REVIEW_POLL_COMMITS_NOW'] = '1'
      begin
        p.process_commit_reviews(proj, now: OUT_WIN,
                                 enqueue_commits: ->(prj, from, to) { calls << [prj, from, to]; true })
      ensure
        ENV.delete('REVIEW_POLL_COMMITS_NOW')
      end
      assert_equal 1, calls.size
    end
  end

  def test_rebaseline_on_unknown_last_sha
    Dir.mktmpdir do |dir|
      master, proj = setup_proj(dir, commits: 3)
      p = poller(dir)
      p.state['pg'] = { 'commit_review' => { 'last_sha' => 'deadbeef' * 5 } }
      p.process_commit_reviews(proj, now: IN_WIN,
                               enqueue_commits: ->(*) { flunk 'must not enqueue' })
      assert_equal rev(master, 'origin/master'), p.state['pg']['commit_review']['last_sha']
    end
  end

  def test_enabled_projects_exposes_commit_review
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'pg'))
      File.write(File.join(dir, 'pg', 'project.yaml'), <<~YAML)
        name: pg
        base_branch: master
        poll:
          enabled: true
        commit_review:
          command: pg:review-commits
          window: "02:00-05:00"
          max_batch: 10
      YAML
      p = poller(dir)
      proj = p.enabled_projects.first
      assert_equal 'pg:review-commits', proj[:commit_review]['command']
    end
  end

  def test_pr_state_writes_preserve_commit_review
    Dir.mktmpdir do |dir|
      p = poller(dir)
      p.state['psp'] = { 'commit_review' => { 'last_sha' => 'abc' } }
      projects = [{ name: 'psp', source: 'o/psp', prefix: 'pr',
                    base_branch: 'main', master_dir: '/tmp/nope' }]
      p.run_once(projects: projects,
                 fetch: ->(_s) { [{ number: 1, head: 'aaa' }] },
                 enqueue: ->(_p, _t) { true },
                 refresh: ->(_p, _b) {})
      assert_equal 'aaa', p.state['psp']['pr1']
      assert_equal({ 'last_sha' => 'abc' }, p.state['psp']['commit_review'])
    end
  end

  def test_first_cycle_with_commit_review_still_baselines_prs
    Dir.mktmpdir do |dir|
      master, proj = setup_proj(dir, commits: 3)
      proj = proj.merge(source: 'o/pg', prefix: 'pr')
      enq = []
      p = poller(dir)
      p.run_once(projects: [proj],
                 fetch: ->(_s) { [{ number: 1, head: 'aaa' }] },
                 enqueue: ->(prj, t) { enq << [prj, t]; true },
                 refresh: ->(_p, _b) {},
                 now: IN_WIN)
      assert_empty enq, 'first cycle must baseline PRs, not enqueue them'
      assert_equal 'aaa', p.state['pg']['pr1']
      assert_equal rev(master, 'origin/master'), p.state['pg']['commit_review']['last_sha']
    end
  end
end

class ReviewPollHackorumClientTest < Minitest::Test
  def with_poller
    Dir.mktmpdir do |dir|
      ENV['REVIEW_POLL_STATE'] = File.join(dir, '.review-poll.state')
      ENV['WORKSPACE_DIR'] = dir
      yield ReviewPoll.new(base_dir: dir), dir
    ensure
      ENV.delete('REVIEW_POLL_STATE')
      ENV.delete('WORKSPACE_DIR')
    end
  end

  def write_project(dir, name, contents)
    FileUtils.mkdir_p(File.join(dir, name))
    File.write(File.join(dir, name, 'project.yaml'), contents)
  end

  def test_enabled_projects_hackorum_flag
    with_poller do |poller, dir|
      write_project(dir, 'pg', "name: pg\nbase_branch: master\npoll:\n  enabled: true\n  hackorum: true\n")
      write_project(dir, 'gh', "name: gh\nsource: o/gh\nbase_branch: main\npoll:\n  enabled: true\n")
      by_name = poller.enabled_projects.to_h { |p| [p[:name], p] }
      assert_equal true, by_name['pg'][:hackorum]
      assert_equal false, by_name['gh'][:hackorum]
    end
  end

  def test_parse_success
    with_poller do |poller, _|
      assert_equal({ 'data' => [] }, poller.hackorum_parse(200, '{"data":[]}'))
    end
  end

  def test_parse_api_error_code
    with_poller do |poller, _|
      e = assert_raises(HackorumError) do
        poller.hackorum_parse(410, '{"error":{"code":"cursor_expired","message":"x"}}')
      end
      assert_equal 410, e.status
      assert_equal 'cursor_expired', e.code
    end
  end

  def test_parse_non_json_error
    with_poller do |poller, _|
      e = assert_raises(HackorumError) { poller.hackorum_parse(502, 'not json') }
      assert_equal 502, e.status
      assert_nil e.code
    end
  end

  def test_parse_non_json_success_raises
    with_poller do |poller, _|
      assert_raises(HackorumError) { poller.hackorum_parse(200, 'not json') }
    end
  end

  def test_get_network_error_is_hackorum_error
    with_poller do |poller, _|
      ENV['HACKORUM_API'] = 'http://127.0.0.1:1/api/v1'
      e = assert_raises(HackorumError) { poller.hackorum_get('/events', since: 'x') }
      assert_equal 0, e.status
    ensure
      ENV.delete('HACKORUM_API')
    end
  end
end

class ReviewPollHackorumTest < Minitest::Test
  NOW = Time.utc(2026, 11, 12, 10, 0, 0).freeze

  def with_poller
    Dir.mktmpdir do |dir|
      ENV['REVIEW_POLL_STATE'] = File.join(dir, '.review-poll.state')
      ENV['WORKSPACE_DIR'] = dir
      ENV['REVIEW_QUEUE_FILE'] = File.join(dir, 'queue')
      ENV['REVIEW_QUEUE_PROCESSED'] = File.join(dir, 'queue.processed')
      proj = { name: 'pg', source: nil, prefix: 't', base_branch: 'master',
               master_dir: File.join(dir, 'pg', 'master'),
               findings_dir: File.join(dir, 'pg', 'findings'),
               only_reviewed: false, hackorum: true }
      yield ReviewPoll.new(base_dir: dir), proj
    ensure
      ENV.delete('REVIEW_POLL_STATE')
      ENV.delete('WORKSPACE_DIR')
      ENV.delete('REVIEW_QUEUE_FILE')
      ENV.delete('REVIEW_QUEUE_PROCESSED')
    end
  end

  def write_queue(lines, offset)
    File.write(ENV['REVIEW_QUEUE_FILE'], lines.map { |l| "#{l}\n" }.join)
    File.write(ENV['REVIEW_QUEUE_PROCESSED'], offset.to_s)
  end

  def branch(id, topic, n, status: 'applied', pushed: true)
    { 'id' => id, 'branch_name' => "t#{topic}_#{n}", 'topic' => { 'id' => topic },
      'status' => status, 'pushed_at' => pushed ? '2026-11-12T09:59:00Z' : nil }
  end

  def ev(br)
    { 'type' => 'branch.created', 'branch' => br }
  end

  # routes: { "/events?since=c1" => page | HackorumError, "/branches/5" => branch | HackorumError }
  def fake_fetch(routes, calls)
    lambda do |path, params = {}|
      key = path == '/events' ? "/events?since=#{params[:since]}" : path
      calls << [path, params]
      r = routes.fetch(key) { raise HackorumError.new(404, 'not_found') }
      raise r if r.is_a?(Exception)
      r
    end
  end

  def page(events, cursor, more: false)
    { 'data' => events, 'next_cursor' => cursor, 'has_more' => more }
  end

  def enq(log, fail: [])
    ->(p, t) { log << [p, t]; !fail.include?(t) }
  end

  def hk(poller)
    poller.state.dig('pg', 'hackorum')
  end

  def test_baseline_stores_cursor_without_enqueue
    with_poller do |poller, proj|
      calls = []
      log = []
      fetch = fake_fetch({ "/events?since=#{NOW.iso8601}" => page([ev(branch(1, 10, 1))], 'c1') }, calls)
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_empty log
      assert_equal 'c1', hk(poller)['cursor']
      assert_equal 'branch.created', calls.first[1][:types]
    end
  end

  def test_pushed_enqueued_failed_skipped_unpushed_pending
    with_poller do |poller, proj|
      poller.state['pg'] = { 'hackorum' => { 'cursor' => 'c1', 'pending' => {}, 'enqueued' => {} } }
      log = []
      fetch = fake_fetch({ '/events?since=c1' => page([
        ev(branch(1, 10, 3)),
        ev(branch(2, 11, 1, status: 'failed', pushed: false)),
        ev(branch(3, 12, 2, pushed: false)),
      ], 'c2') }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_equal [['pg', 't10']], log
      assert_equal 'c2', hk(poller)['cursor']
      assert_equal({ 't10' => 3 }, hk(poller)['enqueued'])
      assert_equal ['3'], hk(poller)['pending'].keys
      assert_equal({ 'topic' => 't12', 'number' => 2, 'seen_at' => NOW.iso8601 }, hk(poller)['pending']['3'])
    end
  end

  def test_pending_recheck_outcomes
    with_poller do |poller, proj|
      old = (NOW - 25 * 3600).iso8601
      poller.state['pg'] = { 'hackorum' => { 'cursor' => 'c1', 'enqueued' => {}, 'pending' => {
        '3' => { 'topic' => 't12', 'number' => 2, 'seen_at' => NOW.iso8601 },
        '4' => { 'topic' => 't13', 'number' => 1, 'seen_at' => NOW.iso8601 },
        '5' => { 'topic' => 't14', 'number' => 1, 'seen_at' => NOW.iso8601 },
        '6' => { 'topic' => 't15', 'number' => 1, 'seen_at' => old },
        '7' => { 'topic' => 't16', 'number' => 1, 'seen_at' => NOW.iso8601 },
      } } }
      calls = []
      log = []
      fetch = fake_fetch({
        '/branches/3' => branch(3, 12, 2),
        '/branches/4' => branch(4, 13, 1, status: 'failed', pushed: false),
        '/branches/5' => HackorumError.new(502, nil),
        '/branches/7' => branch(7, 16, 1, pushed: false),
        '/events?since=c1' => page([], 'c1'),
      }, calls)
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_equal [['pg', 't12']], log
      assert_equal %w[5 6 7], hk(poller)['pending'].keys.sort
      assert_equal 2, hk(poller)['enqueued']['t12']
      refute_includes calls.map(&:first), '/branches/6'
    end
  end

  def test_dedup_by_enqueued_and_findings
    with_poller do |poller, proj|
      FileUtils.mkdir_p(File.join(proj[:findings_dir], 't11', 'v4'))
      poller.state['pg'] = { 'hackorum' => { 'cursor' => 'c1', 'pending' => {}, 'enqueued' => { 't10' => 5 } } }
      log = []
      fetch = fake_fetch({ '/events?since=c1' => page([
        ev(branch(1, 10, 5)), ev(branch(2, 11, 4)), ev(branch(3, 10, 6)),
      ], 'c2') }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_equal [['pg', 't10']], log
      assert_equal 6, hk(poller)['enqueued']['t10']
    end
  end

  def test_only_reviewed
    with_poller do |poller, proj|
      proj = proj.merge(only_reviewed: true)
      FileUtils.mkdir_p(File.join(proj[:findings_dir], 't20', 'v1'))
      poller.state['pg'] = { 'hackorum' => { 'cursor' => 'c1', 'pending' => {}, 'enqueued' => {} } }
      log = []
      fetch = fake_fetch({ '/events?since=c1' => page([ev(branch(1, 20, 2)), ev(branch(2, 21, 1))], 'c2') }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_equal [['pg', 't20']], log
      assert_equal 'c2', hk(poller)['cursor']
    end
  end

  def test_pagination_follows_has_more
    with_poller do |poller, proj|
      poller.state['pg'] = { 'hackorum' => { 'cursor' => 'c1', 'pending' => {}, 'enqueued' => {} } }
      log = []
      fetch = fake_fetch({
        '/events?since=c1' => page([ev(branch(1, 10, 1))], 'c2', more: true),
        '/events?since=c2' => page([ev(branch(2, 11, 1))], 'c3'),
      }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_equal [['pg', 't10'], ['pg', 't11']], log
      assert_equal 'c3', hk(poller)['cursor']
    end
  end

  def test_cursor_expired_rebaselines
    with_poller do |poller, proj|
      poller.state['pg'] = { 'hackorum' => { 'cursor' => 'old', 'pending' => {}, 'enqueued' => { 't10' => 2 } } }
      log = []
      fetch = fake_fetch({
        '/events?since=old' => HackorumError.new(410, 'cursor_expired'),
        "/events?since=#{NOW.iso8601}" => page([ev(branch(1, 11, 1))], 'fresh'),
      }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_empty log
      assert_equal 'fresh', hk(poller)['cursor']
      assert_equal({ 't10' => 2 }, hk(poller)['enqueued'])
    end
  end

  def test_other_error_keeps_cursor
    with_poller do |poller, proj|
      poller.state['pg'] = { 'hackorum' => { 'cursor' => 'c1', 'pending' => {}, 'enqueued' => {} } }
      fetch = fake_fetch({ '/events?since=c1' => HackorumError.new(429, 'rate_limited') }, [])
      log = []
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_equal 'c1', hk(poller)['cursor']
      assert_empty log
    end
  end

  def test_enqueue_failure_stops_page_and_replay_is_safe
    with_poller do |poller, proj|
      poller.state['pg'] = { 'hackorum' => { 'cursor' => 'c1', 'pending' => {}, 'enqueued' => {} } }
      routes = { '/events?since=c1' => page([ev(branch(1, 10, 1)), ev(branch(2, 11, 1)), ev(branch(3, 12, 1))], 'c2') }
      log = []
      poller.process_hackorum(proj, fetch: fake_fetch(routes, []), enqueue: enq(log, fail: ['t11']), now: NOW)
      assert_equal [['pg', 't10'], ['pg', 't11']], log
      assert_equal 'c1', hk(poller)['cursor']
      assert_equal({ 't10' => 1 }, hk(poller)['enqueued'])

      reloaded = ReviewPoll.new(base_dir: poller.base_dir)
      log2 = []
      reloaded.process_hackorum(proj, fetch: fake_fetch(routes, []), enqueue: enq(log2), now: NOW)
      assert_equal [['pg', 't11'], ['pg', 't12']], log2
      assert_equal 'c2', reloaded.state.dig('pg', 'hackorum', 'cursor')
    end
  end

  def test_run_once_calls_hackorum_and_keeps_commit_review
    with_poller do |poller, proj|
      poller.state['pg'] = { 'commit_review' => { 'last_sha' => 'abc' },
                             'hackorum' => { 'cursor' => 'c1', 'pending' => {}, 'enqueued' => {} } }
      log = []
      poller.run_once(projects: [proj],
                      refresh: ->(_p, _b) {},
                      enqueue: enq(log),
                      hackorum_fetch: fake_fetch({ '/events?since=c1' => page([ev(branch(1, 10, 1))], 'c2') }, []),
                      now: NOW)
      assert_equal [['pg', 't10']], log
      assert_equal({ 'last_sha' => 'abc' }, poller.state['pg']['commit_review'])
      assert_equal 'c2', hk(poller)['cursor']
    end
  end

  def test_pr_path_preserves_hackorum_state
    with_poller do |poller, _|
      poller.state['psp'] = { 'pr1' => 'aaa', 'hackorum' => { 'cursor' => 'c9' } }
      projects = [{ name: 'psp', source: 'o/psp', prefix: 'pr', base_branch: 'main', master_dir: '/tmp/nope' }]
      poller.run_once(projects: projects,
                      fetch: ->(_s) { [{ number: 1, head: 'bbb' }] },
                      enqueue: ->(_p, _t) { true },
                      refresh: ->(_p, _b) {})
      assert_equal 'bbb', poller.state['psp']['pr1']
      assert_equal({ 'cursor' => 'c9' }, poller.state['psp']['hackorum'])
    end
  end

  def seeded(poller, enqueued: {})
    poller.state['pg'] = { 'hackorum' => { 'cursor' => 'c1', 'pending' => {}, 'enqueued' => enqueued } }
  end

  def test_nil_data_page_skips_cycle
    with_poller do |poller, proj|
      seeded(poller)
      fetch = fake_fetch({ '/events?since=c1' => { 'data' => nil, 'next_cursor' => 'c2', 'has_more' => false } }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq([]), now: NOW)
      assert_equal 'c1', hk(poller)['cursor']
    end
  end

  def test_event_without_branch_is_skipped
    with_poller do |poller, proj|
      seeded(poller)
      log = []
      fetch = fake_fetch({ '/events?since=c1' => page([
        { 'type' => 'branch.created', 'branch' => nil }, 'junk', ev(branch(1, 10, 1)),
      ], 'c2') }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_equal [['pg', 't10']], log
      assert_equal 'c2', hk(poller)['cursor']
    end
  end

  def test_run_once_survives_hackorum_crash
    with_poller do |poller, proj|
      seeded(poller)
      poller.run_once(projects: [proj], refresh: ->(_p, _b) {}, enqueue: enq([]),
                      hackorum_fetch: ->(_p, _q = {}) { raise 'boom' }, now: NOW)
      assert_equal 'c1', hk(poller)['cursor']
    end
  end

  def test_pending_recheck_drops_malformed
    with_poller do |poller, proj|
      poller.state['pg'] = { 'hackorum' => { 'cursor' => 'c1', 'enqueued' => {}, 'pending' => {
        '3' => { 'topic' => 't12', 'number' => 2, 'seen_at' => NOW.iso8601 },
        '4' => 'garbage',
      } } }
      fetch = fake_fetch({ '/branches/3' => nil, '/events?since=c1' => page([], 'c1') }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq([]), now: NOW)
      assert_empty hk(poller)['pending']
    end
  end

  def test_nil_next_cursor_keeps_cursor
    with_poller do |poller, proj|
      seeded(poller)
      fetch = fake_fetch({ '/events?since=c1' => page([ev(branch(1, 10, 1))], nil) }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq([]), now: NOW)
      assert_equal 'c1', hk(poller)['cursor']
    end
  end

  def test_baseline_nil_cursor_stores_nothing
    with_poller do |poller, proj|
      log = []
      fetch = fake_fetch({ "/events?since=#{NOW.iso8601}" => page([], nil) }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_nil poller.state.dig('pg', 'hackorum', 'cursor')
      assert_empty log
    end
  end

  def test_replayed_unpushed_branch_not_pending_when_enqueued
    with_poller do |poller, proj|
      seeded(poller, enqueued: { 't12' => 2 })
      fetch = fake_fetch({ '/events?since=c1' => page([ev(branch(3, 12, 2, pushed: false))], 'c2') }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq([]), now: NOW)
      assert_empty hk(poller)['pending']
    end
  end

  def test_second_page_enqueue_failure_keeps_first_page_cursor
    with_poller do |poller, proj|
      seeded(poller)
      log = []
      fetch = fake_fetch({
        '/events?since=c1' => page([ev(branch(1, 10, 1))], 'c2', more: true),
        '/events?since=c2' => page([ev(branch(2, 11, 1))], 'c3'),
      }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log, fail: ['t11']), now: NOW)
      assert_equal 'c2', hk(poller)['cursor']
      assert_equal({ 't10' => 1 }, hk(poller)['enqueued'])
    end
  end

  def run_queue_case(lines, offset, events)
    with_poller do |poller, proj|
      seeded(poller)
      write_queue(lines, offset)
      log = []
      enqueue = lambda do |p, t|
        log << [p, t]
        File.open(ENV['REVIEW_QUEUE_FILE'], 'a') { |f| f.puts "#{p} #{t}" }
        true
      end
      fetch = fake_fetch({ '/events?since=c1' => page(events, 'c2') }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enqueue, now: NOW)
      yield poller, log
    end
  end

  def test_skips_topic_waiting_in_queue
    run_queue_case(['pg t1', 'pg t10'], 0, [ev(branch(1, 10, 2))]) do |poller, log|
      assert_empty log
      assert_equal 2, hk(poller)['enqueued']['t10']
      assert_equal 'c2', hk(poller)['cursor']
    end
  end

  def test_topic_at_offset_is_not_waiting
    run_queue_case(['pg t10'], 0, [ev(branch(1, 10, 2))]) do |_poller, log|
      assert_equal [['pg', 't10']], log
    end
  end

  def test_same_run_versions_enqueue_once
    run_queue_case([], 0, [ev(branch(1, 10, 1)), ev(branch(2, 10, 2))]) do |poller, log|
      assert_equal [['pg', 't10']], log
      assert_equal 2, hk(poller)['enqueued']['t10']
    end
  end

  def test_other_project_queue_line_ignored
    run_queue_case(['x', 'gh t10'], 0, [ev(branch(1, 10, 2))]) do |_poller, log|
      assert_equal [['pg', 't10']], log
    end
  end

  def test_queue_without_processed_file_treats_line_zero_as_in_flight
    with_poller do |poller, proj|
      seeded(poller)
      File.write(ENV['REVIEW_QUEUE_FILE'], "pg t1\npg t10\n")
      log = []
      fetch = fake_fetch({ '/events?since=c1' => page([ev(branch(1, 10, 2))], 'c2') }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW)
      assert_empty log
    end
  end

  def test_has_more_without_next_cursor_does_not_loop
    with_poller do |poller, proj|
      seeded(poller)
      log = []
      calls = []
      fetch = fake_fetch({ '/events?since=c1' => { 'data' => [ev(branch(1, 10, 1))], 'next_cursor' => nil, 'has_more' => true } }, calls)
      Timeout.timeout(5) { poller.process_hackorum(proj, fetch: fetch, enqueue: enq(log), now: NOW) }
      assert_equal [['pg', 't10']], log
      assert_equal 'c1', hk(poller)['cursor']
    end
  end

  def test_recheck_stops_after_first_fetch_error
    with_poller do |poller, proj|
      poller.state['pg'] = { 'hackorum' => { 'cursor' => 'c1', 'enqueued' => {}, 'pending' => {
        '3' => { 'topic' => 't12', 'number' => 2, 'seen_at' => NOW.iso8601 },
        '4' => { 'topic' => 't13', 'number' => 1, 'seen_at' => NOW.iso8601 },
        '5' => { 'topic' => 't14', 'number' => 1, 'seen_at' => NOW.iso8601 },
      } } }
      calls = []
      fetch = fake_fetch({ '/branches/3' => HackorumError.new(502, nil), '/events?since=c1' => page([], 'c1') }, calls)
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq([]), now: NOW)
      assert_equal 1, calls.count { |c| c[0].start_with?('/branches/') }
      assert_equal %w[3 4 5], hk(poller)['pending'].keys.sort
    end
  end

  def test_unpushed_branch_without_id_not_pending
    with_poller do |poller, proj|
      seeded(poller)
      fetch = fake_fetch({ '/events?since=c1' => page([ev(branch(nil, 10, 1, pushed: false))], 'c2') }, [])
      poller.process_hackorum(proj, fetch: fetch, enqueue: enq([]), now: NOW)
      assert_empty hk(poller)['pending']
      assert_equal 'c2', hk(poller)['cursor']
    end
  end
end
