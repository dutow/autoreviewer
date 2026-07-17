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
        echo '[{"number":7,"headRefOid":"aaa","baseRefName":"main"}]'
      SH
      FileUtils.chmod(0o755, File.join(bin, 'gh'))
      old = ENV['PATH']
      ENV['PATH'] = "#{bin}:#{old}"
      begin
        prs = poller.open_prs('o/repo')
        assert_equal [{ number: 7, head: 'aaa', base: 'main' }], prs
        assert_includes File.read(log), 'number,headRefOid,baseRefName'
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
