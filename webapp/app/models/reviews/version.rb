module Reviews
  class Version
    attr_reader :topic, :number

    def initialize(topic:, number:)
      @topic = topic
      @number = number
    end

    def dir = File.join(topic.dir, "v#{number}")
    def relpath = dir.delete_prefix(topic.project.root.path + "/")
    def project_name = topic.project.name
    def topic_name = topic.name

    def metadata
      @metadata ||= begin
        JSON.parse(File.read(File.join(dir, "metadata.json")))
      rescue Errno::ENOENT, Errno::ENOTDIR, JSON::ParserError
        {}
      end
    end

    def files
      Dir.glob(File.join(dir, "**", "*"))
         .select { |p| File.file?(p) && !File.symlink?(p) }
         .sort
         .map { |p| FindingsFile.new(version: self, abspath: p) }
    end

    def display_files
      files.reject { |f| f.relpath == "metadata.json" }
    end

    def default_file
      fs = display_files
      fs.find { |f| File.basename(f.relpath, ".*").downcase.include?("summary") } ||
        fs.find { |f| File.basename(f.relpath, ".*").downcase.include?("overview") } ||
        fs.find { |f| f.kind == "markdown" } ||
        fs.first
    end

    def file(relpath)
      base = File.realpath(dir)
      abs = File.realpath(File.join(base, relpath))
      return nil unless abs.start_with?(base + File::SEPARATOR)

      File.file?(abs) ? FindingsFile.new(version: self, abspath: abs) : nil
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, ArgumentError
      nil
    end
  end
end
