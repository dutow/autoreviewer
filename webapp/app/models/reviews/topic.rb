module Reviews
  class Topic
    attr_reader :project, :name

    def initialize(project:, name:)
      @project = project
      @name = name
    end

    def dir = File.join(project.findings_dir, name)

    def versions
      Dir.children(dir).filter_map { |c|
        next unless File.directory?(File.join(dir, c))

        Version.new(topic: self, number: Regexp.last_match(1).to_i) if c =~ /\Av(\d+)\z/
      }.sort_by(&:number)
    end

    def current_version = versions.last

    def version(number)
      v = Version.new(topic: self, number: number.to_i)
      Dir.exist?(v.dir) ? v : nil
    end
  end
end
