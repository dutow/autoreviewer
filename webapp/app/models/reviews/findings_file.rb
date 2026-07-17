module Reviews
  class FindingsFile
    MAX_TEXT_BYTES = 2 * 1024 * 1024

    attr_reader :version, :abspath

    def initialize(version:, abspath:)
      @version = version
      @abspath = abspath
    end

    def relpath = abspath.delete_prefix(version.dir + "/")
    def size = @size ||= File.size(abspath)

    def kind
      @kind ||= case File.extname(abspath).downcase
                when ".md" then "markdown"
                when ".patch", ".diff" then "patch"
                else text? ? "text" : "binary"
                end
    end

    LANGUAGES = {
      ".sql" => "sql", ".sh" => "sh", ".c" => "c",
      ".pl" => "perl", ".py" => "python", ".json" => "json"
    }.freeze

    def language = LANGUAGES[File.extname(abspath).downcase]

    def indexable?
      kind != "binary" && relpath != "metadata.json" && size <= MAX_TEXT_BYTES
    end

    def read_text
      File.read(abspath, encoding: Encoding::UTF_8).scrub
    end

    private

    def text?
      return false if size > MAX_TEXT_BYTES

      sample = File.binread(abspath, 8192) || +""
      !sample.include?("\x00") && sample.force_encoding(Encoding::UTF_8).valid_encoding?
    end
  end
end
