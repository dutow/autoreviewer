class PublicFiles
  DIR = "public"
  SEGMENT_RE = /\A[A-Za-z0-9_-][A-Za-z0-9._-]*\z/
  FS_ERRORS = [Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::ELOOP, Errno::ENAMETOOLONG].freeze

  Entry = Struct.new(:name, :dir, :size, :mtime, keyword_init: true) do
    def dir? = dir
  end

  attr_reader :root

  def initialize(workspace: ENV.fetch("REVIEWS_ROOT"))
    @root = File.realpath(File.join(workspace, DIR))
    @root = nil unless File.directory?(@root)
  rescue *FS_ERRORS
    @root = nil
  end

  def exist? = !@root.nil?

  # real path for relpath, nil if missing, badly named, or outside the root
  def resolve(relpath)
    return nil unless @root

    segs = relpath.to_s.split("/").reject(&:empty?)
    return nil unless segs.all? { |s| s.match?(SEGMENT_RE) }

    inside(File.realpath(File.join(@root, *segs)))
  rescue *FS_ERRORS
    nil
  end

  def entries(abs)
    return [] unless @root

    Dir.children(abs).filter_map do |name|
      next unless name.match?(SEGMENT_RE)

      path = inside(File.realpath(File.join(abs, name))) or next
      st = File.stat(path)
      Entry.new(name: name, dir: st.directory?, size: st.size, mtime: st.mtime)
    rescue *FS_ERRORS
      next
    end.sort_by { |e| [e.dir? ? 0 : 1, e.name] }
  rescue *FS_ERRORS
    []
  end

  private

  def inside(real)
    return nil unless @root

    real == @root || real.start_with?("#{@root}/") ? real : nil
  end
end
