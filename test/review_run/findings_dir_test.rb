require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

require_relative '../../lib/review_run/findings_dir'

class FindingsDirTest < Minitest::Test
  def with_dirs
    Dir.mktmpdir do |root|
      base = File.join(root, 'base')
      proj = File.join(root, 'proj')
      FileUtils.mkdir_p([File.join(base, 'bin'), proj])
      stub = File.join(base, 'bin', 'findings-metadata')
      File.write(stub, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, stub)
      yield base, proj
    end
  end

  def test_prepare_creates_dir_and_symlink
    with_dirs do |base, proj|
      FileUtils.mkdir_p(File.join(proj, 'review', 't'))
      File.write(File.join(proj, 'review', 't', 'metadata.json'), JSON.dump('version' => 3))
      rel = nil
      capture_io { rel = ReviewRun::FindingsDir.prepare(base_dir: base, project_dir: proj, topic: 't') }
      assert_equal 'findings/t/v3', rel
      assert File.directory?(File.join(proj, rel))
      link = File.join(proj, 'current-reviews', 't')
      assert_equal '../findings/t/v3', File.readlink(link)
      assert File.directory?(link)
    end
  end

  def test_prepare_returns_nil_without_metadata
    with_dirs do |base, proj|
      out, = capture_io do
        assert_nil ReviewRun::FindingsDir.prepare(base_dir: base, project_dir: proj, topic: 't')
      end
      assert_match(/WARNING/, out)
    end
  end

  def test_previous_version_picks_highest_with_summary
    with_dirs do |_base, proj|
      { 1 => true, 3 => false, 5 => true }.each do |v, summary|
        d = File.join(proj, 'findings', 't', "v#{v}")
        FileUtils.mkdir_p(d)
        File.write(File.join(d, '05-summary.md'), 'x') if summary
      end
      assert_equal 'findings/t/v1',
                   ReviewRun::FindingsDir.previous_version(project_dir: proj, topic: 't', version: 5)
      assert_nil ReviewRun::FindingsDir.previous_version(project_dir: proj, topic: 't', version: 1)
    end
  end
end
