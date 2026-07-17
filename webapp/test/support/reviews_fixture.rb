require "tmpdir"
require "fileutils"

module ReviewsFixture
  SRC = File.expand_path("../fixtures/reviews_root", __dir__)

  def self.create
    dir = Dir.mktmpdir("reviews_root")
    FileUtils.cp_r(File.join(SRC, "."), dir)
    bin = File.join(dir, "alpha/findings/t1/v2/tests/blob.bin")
    FileUtils.mkdir_p(File.dirname(bin))
    File.binwrite(bin, "\x00\x01\x02BIN")
    system("git", "init", "-q", dir, exception: true)
    system("git", "-C", dir, "add", "-f", ".", exception: true)
    system(git_date_env("2026-05-01T00:00:00Z"),
           "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t",
           "commit", "-qm", "init", exception: true)
    dir
  end

  def self.commit_change(dir, relpath, content, date: "2026-05-02T00:00:00Z")
    abs = File.join(dir, relpath)
    FileUtils.mkdir_p(File.dirname(abs))
    File.write(abs, content)
    system("git", "-C", dir, "add", "-f", ".", exception: true)
    system(git_date_env(date),
           "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t",
           "commit", "-qm", "change", exception: true)
  end

  def self.git_date_env(date)
    { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date }
  end
end
