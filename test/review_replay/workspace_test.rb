require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'stringio'

require_relative '../../lib/review_replay/workspace'
require_relative 'replay_fixture'

class ReplayWorkspaceTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir)
    @live = ReplayFixture.live_workspace(@root)
    @replay_root = File.join(@root, 'replay')
    @out = StringIO.new
    @wsp = ReviewReplay::Workspace.new(workspace_dir: @live, replay_root: @replay_root, out: @out)
  end

  def teardown
    FileUtils.chmod_R('u+rwX', @root)
    FileUtils.rm_rf(@root)
  end

  def prepare(**kw)
    @wsp.prepare(**{ project: 'p', topic: 't1', version: 'v2', route: 'full' }.merge(kw))
  end

  def git(dir, *args)
    ReplayFixture.git(dir, *args)
  end

  def live(*parts)
    File.join(@live, *parts)
  end

  def worktrees
    git(live('p', 'master'), 'worktree', 'list', '--porcelain').scan(/^worktree (.+)$/).flatten
  end

  def test_prepare_creates_run_dir_and_clone
    run = prepare
    assert run.dir.end_with?('replay/p/t1/v2-full-1'), run.dir
    assert_equal File.join(run.dir, 'ws'), run.ws
    assert_equal 2, run.version
    assert File.file?(File.join(run.ws, 'p', 'project.yaml'))
    assert_equal '', git(run.ws, 'remote').strip
  end

  def test_version_forms
    assert_equal 2, prepare(version: '2').version
    assert_equal 2, prepare(version: 2).version
  end

  def test_drops_reference_and_later_versions
    run = prepare
    f = File.join(run.ws, 'p', 'findings', 't1')
    assert File.file?(File.join(f, 'v1', '05-summary.md'))
    refute File.exist?(File.join(f, 'v3'))
    assert_equal ['discussion.txt'], Dir.children(File.join(f, 'v2'))
    assert_includes git(run.ws, 'log', '--format=%s'), "replay: drop t1 v2+\n"
    assert_equal '', git(run.ws, 'status', '--porcelain', '--', 'p/findings/t1/v1', 'p/findings/t1/v3')
  end

  def test_no_drop_commit_when_nothing_to_drop
    git(@live, 'rm', '-r', '-q', '--cached', 'p/findings/t1/v2', 'p/findings/t1/v3')
    git(@live, 'commit', '-q', '-m', 'v2 v3 not committed yet')
    run = prepare
    refute_includes git(run.ws, 'log', '--format=%s'), 'replay: drop'
    assert_equal "thread as of v2\n", File.read(File.join(run.ws, 'p', 'findings', 't1', 'v2', 'discussion.txt'))
  end

  def test_links_live_dirs
    run = prepare
    %w[p/builds p/master q/builds].each do |rel|
      link = File.join(run.ws, rel)
      assert File.symlink?(link), rel
      refute File.readlink(link).start_with?('/'), "#{rel} link not relative: #{File.readlink(link)}"
      assert_equal File.realpath(File.join(@live, rel)), File.realpath(link), rel
    end
    refute File.symlink?(File.join(run.ws, 'p', 'review'))
    refute File.exist?(File.join(run.ws, 'p', 'branches'))
  end

  def test_review_worktree_at_live_head
    run = prepare
    assert_equal git(live('p', 'review', 't1'), 'rev-parse', 'HEAD').strip, git(run.worktree, 'rev-parse', 'HEAD').strip
    assert_equal run.head, git(run.worktree, 'rev-parse', 'HEAD').strip
    assert_equal({ 'version' => 2 }, JSON.parse(File.read(File.join(run.worktree, 'metadata.json'))))
    assert_equal "patch 1\n", File.read(File.join(run.worktree, '.hackorum', '0001.patch'))
    assert_includes worktrees, run.worktree
  end

  def test_seeds_discussion_from_reference
    run = prepare
    assert_equal "thread as of v2\n", File.read(File.join(run.ws, 'p', 'findings', 't1', 'v2', 'discussion.txt'))
  end

  def test_writes_replay_json
    run = prepare
    data = JSON.parse(File.read(File.join(run.dir, 'replay.json')))
    assert_equal %w[created_at head project reference route topic version], data.keys.sort
    assert_equal ['p', 't1', 2, 'full'], data.values_at('project', 'topic', 'version', 'route')
    assert_equal live('p', 'findings', 't1', 'v2'), data['reference']
    assert_equal run.reference, data['reference']
    assert_equal run.head, data['head']
    assert Time.iso8601(data['created_at'])
    assert_equal File.realpath(File.join(run.ws, 'p', 'findings', 't1', 'v2')), File.realpath(File.join(run.dir, 'findings'))
    assert File.directory?(run.state)
  end

  def test_run_number_increments
    first = prepare
    @wsp.cleanup(first)
    second = prepare
    assert second.dir.end_with?('v2-full-2'), second.dir
    other = prepare(route: 'single')
    assert other.dir.end_with?('v2-single-1'), other.dir
  end

  def test_refuses_version_mismatch
    File.write(live('p', 'review', 't1', 'metadata.json'), JSON.generate('version' => 3))
    e = assert_raises(ReviewReplay::ReplayError) { prepare }
    assert_match(/is at v3, not v2/, e.message)
    refute Dir.exist?(@replay_root)
  end

  def test_refuses_unfinished_reference
    File.delete(live('p', 'findings', 't1', 'v2', '05-summary.md'))
    e = assert_raises(ReviewReplay::ReplayError) { prepare }
    assert_match(%r{no finished review at p/findings/t1/v2}, e.message)
  end

  def test_refuses_missing_project_and_ingest
    e = assert_raises(ReviewReplay::ReplayError) { prepare(project: 'nope') }
    assert_match(/project.yaml not found/, e.message)
    File.delete(live('p', 'review', 't1', 'metadata.json'))
    e = assert_raises(ReviewReplay::ReplayError) { prepare }
    assert_match(%r{p/review/t1 not ingested}, e.message)
  end

  def test_refuses_bad_names
    e = assert_raises(ReviewReplay::ReplayError) { prepare(route: '../x') }
    assert_match(/bad name/, e.message)
  end

  def test_failed_prepare_leaves_nothing
    skip 'root ignores file modes' if Process.uid.zero?
    File.chmod(0o000, live('p', 'findings', 't1', 'v2', 'discussion.txt'))
    assert_raises(ReviewReplay::ReplayError) { prepare }
    assert_empty Dir.children(File.join(@replay_root, 'p', 't1'))
    assert_equal [live('p', 'master'), live('p', 'review', 't1')].sort, worktrees.sort
  end

  def test_interrupted_prepare_leaves_nothing
    interrupted = Class.new(ReviewReplay::Workspace) do
      def seed(_run) = raise(Interrupt)
    end.new(workspace_dir: @live, replay_root: @replay_root, out: @out)
    assert_raises(Interrupt) { interrupted.prepare(project: 'p', topic: 't1', version: 'v2', route: 'full') }
    assert_empty Dir.children(File.join(@replay_root, 'p', 't1'))
    assert_equal [live('p', 'master'), live('p', 'review', 't1')].sort, worktrees.sort
  end

  def test_inputs_changed_after_live_commit
    run = prepare
    refute @wsp.inputs_changed?(run)
    review = live('p', 'review', 't1')
    File.write(File.join(review, 'a.c'), "int b;\n")
    git(review, 'commit', '-q', '-am', 'new version')
    assert @wsp.inputs_changed?(run)
  end

  def test_inputs_changed_when_review_gone
    run = prepare
    git(live('p', 'master'), 'worktree', 'remove', '--force', live('p', 'review', 't1'))
    assert @wsp.inputs_changed?(run)
  end

  def test_cleanup_removes_worktree
    run = prepare
    @wsp.cleanup(run)
    refute_includes worktrees, run.worktree
    refute Dir.exist?(run.worktree)
    assert File.file?(File.join(run.dir, 'replay.json'))
  end
end
