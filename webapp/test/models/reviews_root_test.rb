require "test_helper"

class ReviewsRootTest < ActiveSupport::TestCase
  test "lists projects skipping underscore" do
    with_reviews_root do |root, _|
      assert_equal %w[alpha beta], root.projects.map(&:name)
    end
  end

  test "topics versions and current" do
    with_reviews_root do |root, _|
      topic = root.project("alpha").topic("t1")
      assert_equal [1, 2], topic.versions.map(&:number)
      assert_equal 2, topic.current_version.number
    end
  end

  test "metadata parsed and empty when missing" do
    with_reviews_root do |root, _|
      t1 = root.project("alpha").topic("t1")
      assert_equal "Fix qual pushdown", t1.version(2).metadata["title"]
      assert_equal({}, t1.version(1).metadata)
    end
  end

  test "file classification" do
    with_reviews_root do |root, _|
      v2 = root.project("alpha").topic("t1").version(2)
      kinds = v2.files.to_h { |f| [f.relpath, f.kind] }
      assert_equal "markdown", kinds["00-overview.md"]
      assert_equal "patch", kinds["patches/fix.patch"]
      assert_equal "binary", kinds["tests/blob.bin"]
      refute v2.file("metadata.json").indexable?

      pr5 = root.project("beta").topic("pr5").version(1)
      beta_kinds = pr5.files.to_h { |f| [f.relpath, f.kind] }
      assert_equal "text", beta_kinds["discussion.txt"]
    end
  end

  test "findings file language maps known extensions" do
    lang = ->(name) { Reviews::FindingsFile.new(version: nil, abspath: "/x/#{name}").language }
    assert_equal "sql", lang.call("q.sql")
    assert_equal "sh", lang.call("run.SH")
    assert_equal "c", lang.call("t.c")
    assert_equal "perl", lang.call("t.pl")
    assert_equal "python", lang.call("t.py")
    assert_equal "json", lang.call("m.json")
    assert_nil lang.call("notes.txt")
    assert_nil lang.call("noext")
  end

  test "stray file named like a version is ignored" do
    with_reviews_root do |root, dir|
      File.write(File.join(dir, "alpha/findings/t1/v3"), "not a dir")
      topic = root.project("alpha").topic("t1")
      assert_equal [1, 2], topic.versions.map(&:number)
      assert_equal 2, topic.current_version.number
      assert_nil topic.version(3)
    end
  end

  test "root reached via symlink still resolves relpaths" do
    with_reviews_root do |root_direct, dir|
      link = File.join(Dir.mktmpdir("reviews_link"), "root")
      File.symlink(dir, link)
      begin
        root = ReviewsRoot.new(path: link)
        v2 = root.project("alpha").topic("t1").version(2)
        assert_equal "00-overview.md", v2.file("00-overview.md").relpath
        refute v2.file("metadata.json").indexable?
      ensure
        FileUtils.remove_entry(File.dirname(link))
      end
    end
  end

  test "path traversal rejected" do
    with_reviews_root do |root, dir|
      v2 = root.project("alpha").topic("t1").version(2)
      assert_nil v2.file("../../t1/v1/00-overview.md")
      assert_nil v2.file("/etc/passwd")
      File.symlink("/etc", File.join(v2.dir, "esc"))
      assert_nil v2.file("esc/passwd")
      assert_equal "00-overview.md", v2.file("00-overview.md").relpath
    end
  end

  test "dir without project.yaml is not a project" do
    with_reviews_root do |root, dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "some-script"), "junk")

      refute_includes root.projects.map(&:name), "bin"
      assert_nil root.project("bin")
    end
  end

  test "unknown names return nil" do
    with_reviews_root do |root, _|
      assert_nil root.project("_template")
      assert_nil root.project("nope")
      assert_nil root.project("alpha").topic("nope")
      assert_nil root.project("alpha").topic("t1").version(99)
    end
  end

  test "git head" do
    with_reviews_root do |root, _|
      assert_match(/\A[0-9a-f]{40}\z/, root.git_head)
    end
  end

  test "display files hide metadata and default file prefers summary then overview" do
    with_reviews_root do |root, _|
      v2 = root.project("alpha").topic("t1").version(2)
      refute_includes v2.display_files.map(&:relpath), "metadata.json"
      assert_equal "00-overview.md", v2.default_file.relpath

      File.write(File.join(v2.dir, "05-summary.md"), "# Summary\n")
      assert_equal "05-summary.md", root.project("alpha").topic("t1").version(2).default_file.relpath
    end
  end

  test "default file falls back to first markdown then first file" do
    with_reviews_root do |root, dir|
      v3dir = File.join(dir, "alpha/findings/t1/v3")
      FileUtils.mkdir_p(v3dir)
      File.write(File.join(v3dir, "aa-data.txt"), "d")
      File.write(File.join(v3dir, "zz-notes.md"), "n")
      topic = root.project("alpha").topic("t1")
      assert_equal "zz-notes.md", topic.version(3).default_file.relpath

      File.delete(File.join(v3dir, "zz-notes.md"))
      assert_equal "aa-data.txt", topic.version(3).default_file.relpath

      File.delete(File.join(v3dir, "aa-data.txt"))
      assert_nil topic.version(3).default_file
    end
  end
end
