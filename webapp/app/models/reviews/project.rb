module Reviews
  class Project
    attr_reader :root, :name

    def initialize(root:, name:)
      @root = root
      @name = name
    end

    def findings_dir = File.join(root.path, name, "findings")

    def topics
      return [] unless Dir.exist?(findings_dir)

      Dir.children(findings_dir).sort.filter_map { |t| topic(t) }
    end

    def topic(topic_name)
      return nil unless topic_name =~ ReviewsRoot::NAME_RE

      dir = File.join(findings_dir, topic_name)
      Dir.exist?(dir) ? Topic.new(project: self, name: topic_name) : nil
    end
  end
end
