require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class CheckCommandDriftTest < Minitest::Test
  SCRIPT = File.expand_path('../bin/check-command-drift', __dir__)
  CMD = "# Review <PROJECT>\n\nspine line\n"
  SHARED = "shared <PROJECT>\n<!-- project-specific:start -->\ngeneric\n<!-- project-specific:end -->\ntail\n"
  TPL = '_' + 'git-pr'

  def setup
    @ws = Dir.mktmpdir
    write(".claude/commands/#{TPL}/review-patch.md", CMD)
    write(".claude/review-phases/#{TPL}/shared.md", SHARED)
    write(".claude/review-phases/#{TPL}/01-overview.md", "overview <PROJECT>\n")
    write('proj/project.yaml', "name: proj\ningestion:\n  hook: github-pr\n")
    write('.claude/commands/proj/review-patch.md', CMD.gsub('<PROJECT>', 'proj'))
    write('.claude/review-phases/proj/shared.md', SHARED.gsub('<PROJECT>', 'proj'))
    write('.claude/review-phases/proj/01-overview.md', "overview proj\n")
  end

  def teardown
    FileUtils.rm_rf(@ws)
  end

  def write(rel, text)
    path = File.join(@ws, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def run_check
    Open3.capture2e({ 'WORKSPACE_DIR' => @ws }, SCRIPT)
  end

  def test_clean_phase_dirs_ok
    out, st = run_check
    assert st.success?, out
    assert_includes out, 'proj: OK'
  end

  def test_spine_change_in_phase_file_is_drift
    write('.claude/review-phases/proj/01-overview.md', "overview changed\n")
    out, st = run_check
    refute st.success?
    assert_includes out, 'DRIFT'
    assert_includes out, '01-overview.md'
  end

  def test_project_specific_region_ignored
    write('.claude/review-phases/proj/shared.md',
          "shared proj\n<!-- project-specific:start -->\nlocal stuff\n<!-- project-specific:end -->\ntail\n")
    out, st = run_check
    assert st.success?, out
  end

  def test_missing_phase_file_is_drift
    FileUtils.rm(File.join(@ws, '.claude/review-phases/proj/01-overview.md'))
    out, st = run_check
    refute st.success?
    assert_includes out, '01-overview.md'
  end

  def test_extra_phase_file_is_drift
    write('.claude/review-phases/proj/99-extra.md', "x\n")
    out, st = run_check
    refute st.success?
    assert_includes out, '99-extra.md'
  end
end
