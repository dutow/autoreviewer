require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'time'

load File.expand_path('../bin/findings-metadata', __dir__)

class FindingsMetadataTest < Minitest::Test
  NOW = Time.utc(2026, 7, 3, 12, 0, 0)

  def with_workspace
    Dir.mktmpdir do |dir|
      yield FindingsMetadata.new(base_dir: dir, now: NOW), dir
    end
  end

  def write_project(dir, name, yaml)
    pdir = File.join(dir, name)
    FileUtils.mkdir_p(pdir)
    File.write(File.join(pdir, 'project.yaml'), yaml)
    pdir
  end

  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(data))
  end

  def test_write_topic_from_normalized_metadata
    with_workspace do |fm, dir|
      pdir = write_project(dir, 'postgres', "name: postgres\n")
      write_json(File.join(pdir, 'review', 't1', 'metadata.json'),
                 'version' => 3, 'source_url' => 'https://example.org/thread')
      FileUtils.mkdir_p(File.join(pdir, 'findings', 't1', 'v3'))

      out = fm.write_topic(File.join(pdir, 'project.yaml'), 't1')
      data = JSON.parse(File.read(out))
      assert_equal 'postgres', data['project']
      assert_equal 3, data['version']
      assert_equal 'https://example.org/thread', data['source_url']
      assert_equal NOW.iso8601, data['reviewed_at']
    end
  end

  def test_hackorum_fallback_fills_urls
    with_workspace do |fm, dir|
      pdir = write_project(dir, 'postgres', "name: postgres\n")
      write_json(File.join(pdir, 'review', 't2', 'metadata.json'), 'version' => 1)
      write_json(File.join(pdir, 'review', 't2', '.hackorum', 'metadata.json'),
                 'hackorum_url' => 'https://hackorum.dev/topics/2',
                 'upstream_url' => 'https://example.org/up')
      FileUtils.mkdir_p(File.join(pdir, 'findings', 't2', 'v1'))

      data = JSON.parse(File.read(fm.write_topic(File.join(pdir, 'project.yaml'), 't2')))
      assert_equal 'https://example.org/up', data['source_url']
      assert_equal 'https://hackorum.dev/topics/2', data['hackorum_url']
    end
  end

  def test_title_from_discussion_pr_line_beats_generic_overview
    with_workspace do |fm, dir|
      pdir = write_project(dir, 'pg_tde', "name: pg_tde\nsource: percona/pg_tde\n")
      write_json(File.join(pdir, 'review', 'pr7', 'metadata.json'), 'version' => 2)
      vdir = File.join(pdir, 'findings', 'pr7', 'v2')
      FileUtils.mkdir_p(vdir)
      File.write(File.join(vdir, '00-overview.md'), "# PR Overview: pr7 v2\n\nbody\n")
      File.write(File.join(vdir, 'discussion.txt'), "PR #7: Fix WAL encryption\n\n...")

      data = JSON.parse(File.read(fm.write_topic(File.join(pdir, 'project.yaml'), 'pr7')))
      assert_equal 'Fix WAL encryption', data['title']
    end
  end

  def test_pr_url_derived_from_source
    with_workspace do |fm, dir|
      pdir = write_project(dir, 'pg_tde', "name: pg_tde\nsource: percona/pg_tde\n")
      write_json(File.join(pdir, 'review', 'pr751', 'metadata.json'), 'version' => 1)
      FileUtils.mkdir_p(File.join(pdir, 'findings', 'pr751', 'v1'))

      data = JSON.parse(File.read(fm.write_topic(File.join(pdir, 'project.yaml'), 'pr751')))
      assert_equal 'https://github.com/percona/pg_tde/pull/751', data['source_url']
    end
  end

  def test_title_from_normalized_metadata_beats_heuristics
    with_workspace do |fm, dir|
      pdir = write_project(dir, 'postgres', "name: postgres\n")
      write_json(File.join(pdir, 'review', 't4', 'metadata.json'),
                 'version' => 2, 'title' => 'Add frobnication to WAL')
      vdir = File.join(pdir, 'findings', 't4', 'v2')
      FileUtils.mkdir_p(vdir)
      File.write(File.join(vdir, '00-overview.md'), "# Some other heading\n")

      data = JSON.parse(File.read(fm.write_topic(File.join(pdir, 'project.yaml'), 't4')))
      assert_equal 'Add frobnication to WAL', data['title']
    end
  end

  def test_backfill_titles_fetches_missing_and_caches
    pages = { 'https://hackorum.dev/topics/9' =>
                "<html><head><title>Fix the planner - Hackorum</title></head></html>" }
    calls = []
    http = lambda { |url| calls << url; pages[url] }
    Dir.mktmpdir do |dir|
      fm = FindingsMetadata.new(base_dir: dir, now: NOW, http: http)
      pdir = write_project(dir, 'postgres', "name: postgres\n")
      %w[v1 v2].each do |v|
        write_json(File.join(pdir, 'findings', 't9', v, 'metadata.json'),
                   'project' => 'postgres', 'topic' => 't9', 'version' => v.delete('v').to_i,
                   'hackorum_url' => 'https://hackorum.dev/topics/9',
                   'reviewed_at' => '2026-01-01T00:00:00Z')
      end
      done = File.join(pdir, 'findings', 't8', 'v1', 'metadata.json')
      write_json(done, 'title' => 'Already there', 'source_url' => 'https://example.org/x')

      assert_equal 2, fm.backfill_titles
      %w[v1 v2].each do |v|
        data = JSON.parse(File.read(File.join(pdir, 'findings', 't9', v, 'metadata.json')))
        assert_equal 'Fix the planner', data['title']
        assert_equal '2026-01-01T00:00:00Z', data['reviewed_at']
      end
      assert_equal 1, calls.length
      assert_equal 'Already there', JSON.parse(File.read(done))['title']
    end
  end

  def test_clean_title_strips_postgresql_prefix_and_wrapping
    with_workspace do |fm, _dir|
      raw = "<title>PostgreSQL: [PATCH v1] Add ssl_alt_cert_file\n for dual RSA+ECDSA</title>"
      assert_equal '[PATCH v1] Add ssl_alt_cert_file for dual RSA+ECDSA',
                   fm.send(:title_from_html, raw)
    end
  end

  def test_clean_title_unescapes_double_encoded_entities
    with_workspace do |fm, _dir|
      raw = '<title>REPACK blocks on sessions&amp;#39; temp tables - Hackorum</title>'
      assert_equal "REPACK blocks on sessions' temp tables",
                   fm.send(:title_from_html, raw)
    end
  end

  def test_title_from_non_generic_overview_heading
    with_workspace do |fm, dir|
      pdir = write_project(dir, 'postgres', "name: postgres\n")
      write_json(File.join(pdir, 'review', 't3', 'metadata.json'), 'version' => 1)
      vdir = File.join(pdir, 'findings', 't3', 'v1')
      FileUtils.mkdir_p(vdir)
      File.write(File.join(vdir, '00-overview.md'), "# Fix qual pushdown\n\nbody\n")

      data = JSON.parse(File.read(fm.write_topic(File.join(pdir, 'project.yaml'), 't3')))
      assert_equal 'Fix qual pushdown', data['title']
    end
  end

  def test_reviewed_at_preserved_on_rerun
    with_workspace do |fm, dir|
      pdir = write_project(dir, 'postgres', "name: postgres\n")
      write_json(File.join(pdir, 'review', 't1', 'metadata.json'), 'version' => 1)
      vdir = File.join(pdir, 'findings', 't1', 'v1')
      FileUtils.mkdir_p(vdir)
      write_json(File.join(vdir, 'metadata.json'),
                 'project' => 'postgres', 'topic' => 't1', 'version' => 1,
                 'reviewed_at' => '2026-01-01T00:00:00Z')

      data = JSON.parse(File.read(fm.write_topic(File.join(pdir, 'project.yaml'), 't1')))
      assert_equal '2026-01-01T00:00:00Z', data['reviewed_at']
    end
  end

  def test_write_topic_skips_when_no_version
    with_workspace do |fm, dir|
      pdir = write_project(dir, 'postgres', "name: postgres\n")
      assert_nil fm.write_topic(File.join(pdir, 'project.yaml'), 'missing')
    end
  end

  def test_backfill_uses_git_commit_time_and_skips_existing
    with_workspace do |fm, dir|
      pdir = write_project(dir, 'postgres', "name: postgres\n")
      vdir = File.join(pdir, 'findings', 't9', 'v2')
      FileUtils.mkdir_p(vdir)
      File.write(File.join(vdir, '00-overview.md'), "# Patch Overview: t9 v2\n")
      done = File.join(pdir, 'findings', 't8', 'v1')
      FileUtils.mkdir_p(done)
      write_json(File.join(done, 'metadata.json'), 'reviewed_at' => 'KEEP')

      system('git', 'init', '-q', dir)
      system('git', '-C', dir, 'add', '.', exception: true)
      system('git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t',
             'commit', '-qm', 'init', exception: true)

      fm.backfill
      data = JSON.parse(File.read(File.join(vdir, 'metadata.json')))
      assert_equal 't9', data['topic']
      assert_equal 2, data['version']
      refute_nil data['reviewed_at']
      assert_equal 'KEEP', JSON.parse(File.read(File.join(done, 'metadata.json')))['reviewed_at']
    end
  end
end
