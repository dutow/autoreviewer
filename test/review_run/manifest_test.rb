require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

require_relative '../../lib/review_run/manifest'

class ManifestTest < Minitest::Test
  def with_manifest(yaml, prompts: %w[01-a.md 02-b.md])
    Dir.mktmpdir do |dir|
      prompts.each { |p| File.write(File.join(dir, p), 'x') }
      path = File.join(dir, 'phases.yaml')
      File.write(path, yaml)
      yield path, dir
    end
  end

  YAML_OK = <<~Y
    default_model: opus
    routes:
      full:
        - name: overview
          prompt: 01-a.md
          output: 00-overview.md
        - name: deep
          prompt: 02-b.md
          model: sonnet
          effort: high
          shared: true
  Y

  def test_loads_route_in_order
    with_manifest(YAML_OK) do |path, dir|
      m = ReviewRun::Manifest.load(path)
      phases = m.route('full')
      assert_equal %w[overview deep], phases.map(&:name)
      assert_equal '00-overview.md', phases[0].output
      assert_equal 'high', phases[1].effort
      assert_equal true, phases[1].shared
      assert_equal File.realpath(dir), File.realpath(m.dir)
      assert_equal File.join(m.dir, '01-a.md'), m.prompt_path(phases[0])
    end
  end

  def test_default_model_applied
    with_manifest(YAML_OK) do |path, _|
      phases = ReviewRun::Manifest.load(path).route('full')
      assert_equal 'opus', phases[0].model
      assert_equal 'sonnet', phases[1].model
    end
  end

  def test_unknown_route_raises
    with_manifest(YAML_OK) do |path, _|
      assert_raises(ReviewRun::ManifestError) { ReviewRun::Manifest.load(path).route('nope') }
    end
  end

  def test_missing_prompt_file_raises
    with_manifest(YAML_OK, prompts: %w[01-a.md]) do |path, _|
      assert_raises(ReviewRun::ManifestError) { ReviewRun::Manifest.load(path) }
    end
  end

  def test_duplicate_phase_name_raises
    yaml = <<~Y
      routes:
        full:
          - { name: a, prompt: 01-a.md }
          - { name: a, prompt: 02-b.md }
    Y
    with_manifest(yaml) do |path, _|
      assert_raises(ReviewRun::ManifestError) { ReviewRun::Manifest.load(path) }
    end
  end

  def test_skip_if_matches_post_line
    yaml = <<~Y
      default_model: opus
      routes:
        full:
          - name: a
            prompt: 01-a.md
            skip_if: { file: 05-summary.md, match: '^\\*\\*Post:\\*\\* (nothing to post|moot)' }
    Y
    with_manifest(yaml) do |path, _|
      phase = ReviewRun::Manifest.load(path).route('full').first
      Dir.mktmpdir do |out|
        refute phase.skip?(out)
        File.write(File.join(out, '05-summary.md'), "x\n**Post:** nothing to post\n")
        assert phase.skip?(out)
        File.write(File.join(out, '05-summary.md'), "x\n**Post:** yes, 2 points\n")
        refute phase.skip?(out)
      end
    end
  end
end
