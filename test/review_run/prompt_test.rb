require 'minitest/autorun'
require 'tmpdir'

require_relative '../../lib/review_run/manifest'
require_relative '../../lib/review_run/prompt'

class PromptTest < Minitest::Test
  def with_setup(shared_body: "shared $PROJECT\n", phase_body: "body $ARGUMENTS $OUTDIR $PROJECT\n", shared: false)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'shared.md'), shared_body)
      File.write(File.join(dir, '01-a.md'), phase_body)
      File.write(File.join(dir, 'phases.yaml'), <<~Y)
        routes:
          full:
            - name: design
              prompt: 01-a.md
              shared: #{shared}
      Y
      m = ReviewRun::Manifest.load(File.join(dir, 'phases.yaml'))
      yield m, m.route('full').first
    end
  end

  def ctx(**over)
    ReviewRun::Context.new(**{ project: 'postgres', topic: 't1', version: 'v3',
                               outdir: 'postgres/findings/t1/v3', prev_dir: nil,
                               index: 2, total: 7 }.merge(over))
  end

  def test_header_fields
    with_setup do |m, ph|
      out = ReviewRun::Prompt.render(manifest: m, phase: ph, ctx: ctx)
      assert out.start_with?("# Automated review phase\n\nProject: postgres\n")
      assert_includes out, "Phase: design (2 of 7)\n"
      assert_includes out, "Output directory: postgres/findings/t1/v3\n"
      assert_includes out, "Review worktree: postgres/review/t1\n"
      assert_includes out, "Previous reviewed version: none\n"
      assert_includes out, "All paths are relative to the workspace root (the current directory).\n"
    end
  end

  def test_prev_dir_shown
    with_setup do |m, ph|
      out = ReviewRun::Prompt.render(manifest: m, phase: ph, ctx: ctx(prev_dir: 'postgres/findings/t1/v2'))
      assert_includes out, "Previous reviewed version: postgres/findings/t1/v2\n"
    end
  end

  def test_substitutes_arguments_outdir_project
    with_setup do |m, ph|
      out = ReviewRun::Prompt.render(manifest: m, phase: ph, ctx: ctx)
      assert_includes out, "body t1 postgres/findings/t1/v3 postgres\n"
    end
  end

  def test_shared_inlined_only_when_flagged
    with_setup(shared: true) do |m, ph|
      out = ReviewRun::Prompt.render(manifest: m, phase: ph, ctx: ctx)
      assert_includes out, "shared postgres\n"
      assert_operator out.index('shared postgres'), :<, out.index('body t1')
    end
    with_setup(shared: false) do |m, ph|
      refute_includes ReviewRun::Prompt.render(manifest: m, phase: ph, ctx: ctx), 'shared postgres'
    end
  end

  def test_frontmatter_stripped
    with_setup(phase_body: "---\ndescription: x\n---\nreal body\n") do |m, ph|
      out = ReviewRun::Prompt.render(manifest: m, phase: ph, ctx: ctx)
      assert_includes out, 'real body'
      refute_includes out, 'description: x'
    end
  end

  def test_render_command_has_no_header
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'c.md')
      File.write(path, "---\nmodel: x\n---\nreview $ARGUMENTS\n")
      out = ReviewRun::Prompt.render_command(path: path, args: 'abc123')
      assert_equal "review abc123\n", out
    end
  end
end
