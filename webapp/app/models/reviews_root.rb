require "open3"

class ReviewsRoot
  NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  attr_reader :path

  def initialize(path: ENV.fetch("REVIEWS_ROOT"))
    @path = File.realpath(File.expand_path(path))
  end

  def projects
    Dir.glob(File.join(@path, "*", "project.yaml")).sort.filter_map do |yaml|
      project(File.basename(File.dirname(yaml)))
    end
  end

  def project(name)
    return nil unless name =~ NAME_RE && !name.start_with?("_")

    dir = File.join(@path, name)
    return nil unless File.file?(File.join(dir, "project.yaml"))

    Reviews::Project.new(root: self, name: name)
  end

  def git_head
    out, status = git("rev-parse", "HEAD")
    status.success? ? out.strip : nil
  end

  def git(*args)
    out, err, status = Open3.capture3("git", "-C", @path, *args)
    Rails.logger.debug("git #{args.first}: #{err.strip}") unless err.empty?
    [out, status]
  end
end
