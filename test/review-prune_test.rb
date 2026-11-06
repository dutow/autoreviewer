require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

load File.expand_path('../bin/review-prune', __dir__)

class ReviewPruneTest < Minitest::Test
  DAY = 86_400

  def with_workspace
    Dir.mktmpdir do |dir|
      yield dir
    end
  end

  def mkdir_aged(path, days, file: nil)
    FileUtils.mkdir_p(path)
    t = Time.now - days * DAY
    if file
      f = File.join(path, file)
      File.write(f, "x")
      FileUtils.touch(f, mtime: t)
    end
    FileUtils.touch(path, mtime: t)
  end

  def proj(dir, name)
    pdir = File.join(dir, name)
    FileUtils.mkdir_p(pdir)
    FileUtils.touch(File.join(pdir, 'project.yaml'))
    pdir
  end

  def pruner(dir, days: 7, active: [])
    ReviewPrune.new(workspace_dir: dir, days: days, active_windows: active)
  end

  def topics(plan)
    plan.map { |c| [c[:project], c[:topic]] }
  end

  def test_old_topic_is_candidate_young_is_not
    with_workspace do |dir|
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr1'), 10)
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr2'), 2)
      assert_equal [['pg', 'pr1']], topics(pruner(dir).candidates)
    end
  end

  def test_age_is_newest_of_builds_review_and_status
    with_workspace do |dir|
      # old build dir but fresh status.yaml inside a config: rebuilt recently
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr1'), 30)
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr1', 'debug'), 30, file: 'status.yaml')
      FileUtils.touch(File.join(proj(dir, 'pg'), 'builds', 'pr1', 'debug', 'status.yaml'), mtime: Time.now - 1 * DAY)
      # old build, fresh review worktree
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr2'), 30)
      mkdir_aged(File.join(proj(dir, 'pg'), 'review', 'pr2'), 1, file: 'metadata.json')
      # both old
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr3'), 30)
      mkdir_aged(File.join(proj(dir, 'pg'), 'review', 'pr3'), 20, file: 'metadata.json')
      # review only, old
      mkdir_aged(File.join(proj(dir, 'pg'), 'review', 'pr4'), 9, file: 'metadata.json')
      assert_equal [['pg', 'pr3'], ['pg', 'pr4']], topics(pruner(dir).candidates)
    end
  end

  def test_master_and_branch_builds_are_kept
    with_workspace do |dir|
      mkdir_aged(File.join(proj(dir, 'psp'), 'builds', 'master'), 60)
      mkdir_aged(File.join(proj(dir, 'psp'), 'builds', 'REL_18_STABLE'), 60)
      mkdir_aged(File.join(proj(dir, 'psp'), 'branches', 'REL_18_STABLE'), 60)
      mkdir_aged(File.join(proj(dir, 'psp'), 'builds', 'pr9'), 60)
      assert_equal [['psp', 'pr9']], topics(pruner(dir).candidates)
    end
  end

  def test_running_review_is_kept
    with_workspace do |dir|
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr1'), 60)
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr2'), 60)
      assert_equal [['pg', 'pr2']], topics(pruner(dir, active: ['pg-pr1', 'orchestrator']).candidates)
    end
  end

  def test_zero_days_disables
    with_workspace do |dir|
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr1'), 60)
      assert_empty pruner(dir, days: 0).candidates
    end
  end

  def test_run_removes_builds_and_worktree_and_branch
    with_workspace do |dir|
      master = File.join(proj(dir, 'pg'), 'master')
      FileUtils.mkdir_p(master)
      git = ->(*a) { system('git', '-C', master, *a, out: File::NULL, err: File::NULL) or flunk "git #{a.join(' ')}" }
      git.('init', '-q', '-b', 'main')
      git.('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'init')
      review = File.join(proj(dir, 'pg'), 'review', 'pr1')
      git.('worktree', 'add', '-q', '-B', 'review/pr1', review, 'HEAD')
      FileUtils.touch(review, mtime: Time.now - 30 * DAY)
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr1', 'debug'), 30, file: 'status.yaml')
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr1'), 30)
      mkdir_aged(File.join(proj(dir, 'pg'), 'builds', 'pr2'), 1)

      out = StringIO.new
      pruner(dir).run(dry_run: true, out: out)
      assert File.exist?(review)
      assert File.exist?(File.join(proj(dir, 'pg'), 'builds', 'pr1'))
      assert_match(/pg\/pr1/, out.string)

      pruner(dir).run(out: StringIO.new)
      refute File.exist?(review)
      refute File.exist?(File.join(proj(dir, 'pg'), 'builds', 'pr1'))
      assert File.exist?(File.join(proj(dir, 'pg'), 'builds', 'pr2'))
      wt = `git -C #{master} worktree list`
      refute_match(/review\/pr1/, wt)
      refute system('git', '-C', master, 'rev-parse', '-q', '--verify', 'refs/heads/review/pr1', out: File::NULL, err: File::NULL)
    end
  end

  def test_run_without_master_repo_still_removes_dirs
    with_workspace do |dir|
      mkdir_aged(File.join(proj(dir, 'pg'), 'review', 'pr1'), 30, file: 'metadata.json')
      pruner(dir).run(out: StringIO.new)
      refute File.exist?(File.join(proj(dir, 'pg'), 'review', 'pr1'))
    end
  end
end
