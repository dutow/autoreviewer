require "test_helper"

class PublicFilesTest < ActiveSupport::TestCase
  setup do
    @ws = Dir.mktmpdir("ws")
    @pub = File.join(@ws, "public")
    write("readme.txt", "hi")
    write("site/index.html", "<p>x</p>")
    write("site/.hidden", "h")
    FileUtils.mkdir_p(File.join(@pub, "empty"))
    File.symlink("/etc", File.join(@pub, "escape"))
    File.symlink("/nonexistent", File.join(@pub, "dangling"))
    File.symlink(File.join(@pub, "readme.txt"), File.join(@pub, "alias.txt"))
    @files = PublicFiles.new(workspace: @ws)
  end

  teardown { FileUtils.remove_entry(@ws) }

  def write(rel, content)
    abs = File.join(@pub, rel)
    FileUtils.mkdir_p(File.dirname(abs))
    File.write(abs, content)
  end

  test "missing public dir" do
    Dir.mktmpdir("nopub") do |ws|
      files = PublicFiles.new(workspace: ws)
      refute files.exist?
      assert_nil files.resolve("")
      assert_equal [], files.entries("/etc")
    end
  end

  test "resolve root and nested file" do
    assert @files.exist?
    assert_equal File.realpath(@pub), @files.resolve("")
    assert_equal File.realpath(File.join(@pub, "site/index.html")), @files.resolve("site/index.html")
    assert_equal File.realpath(File.join(@pub, "readme.txt")), @files.resolve("alias.txt"),
                 "symlink inside the root is fine"
  end

  test "resolve rejects bad paths" do
    assert_nil @files.resolve("../public/readme.txt")
    assert_nil @files.resolve("site/.hidden")
    assert_nil @files.resolve("site/a b.txt")
    assert_nil @files.resolve("nope.txt")
    assert_nil @files.resolve("escape/passwd")
    assert_nil @files.resolve("escape")
    assert_nil @files.resolve("readme.txt/x"), "file used as a directory"
    assert_nil @files.resolve("a" * 300)
  end

  test "entries dirs first, hidden and escaping skipped" do
    names = @files.entries(@files.resolve("")).map { |e| [e.name, e.dir?] }
    assert_equal [["empty", true], ["site", true], ["alias.txt", false], ["readme.txt", false]], names
    site = @files.entries(@files.resolve("site"))
    assert_equal ["index.html"], site.map(&:name)
    assert_equal 8, site.first.size
    assert_kind_of Time, site.first.mtime
  end
end
