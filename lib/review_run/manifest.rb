require 'yaml'

module ReviewRun
  class ManifestError < StandardError; end

  Phase = Struct.new(:name, :prompt, :output, :model, :effort, :shared, :skip_if, keyword_init: true) do
    def skip?(outdir_abs)
      return false unless skip_if

      file = File.join(outdir_abs, skip_if['file'])
      return false unless File.file?(file)

      File.read(file).match?(Regexp.new(skip_if['match']))
    end
  end

  class Manifest
    attr_reader :dir

    def self.load(path)
      new(path)
    end

    def initialize(path)
      path = File.expand_path(path)
      @dir = File.dirname(path)
      data = YAML.safe_load_file(path) || {}
      raise ManifestError, "#{path}: not a mapping" unless data.is_a?(Hash)

      routes = data['routes']
      raise ManifestError, "#{path}: missing routes" unless routes.is_a?(Hash)

      @routes = routes.to_h do |rname, list|
        [rname, build_route(rname, list, data['default_model'], data['default_effort'])]
      end
    end

    def route(name)
      @routes.fetch(name) { raise ManifestError, "unknown route: #{name}" }
    end

    def prompt_path(phase)
      File.join(@dir, phase.prompt)
    end

    private

    def build_route(rname, list, default_model, default_effort)
      raise ManifestError, "route #{rname}: expected a list" unless list.is_a?(Array)

      seen = {}
      list.map do |h|
        raise ManifestError, "route #{rname}: phase is not a mapping" unless h.is_a?(Hash)

        name = h['name']
        prompt = h['prompt']
        raise ManifestError, "route #{rname}: phase missing name" if name.to_s.empty?
        raise ManifestError, "route #{rname}: phase #{name} missing prompt" if prompt.to_s.empty?
        raise ManifestError, "route #{rname}: duplicate phase #{name}" if seen[name]

        seen[name] = true
        unless File.file?(File.join(@dir, prompt))
          raise ManifestError, "route #{rname}: phase #{name}: prompt not found: #{prompt}"
        end

        Phase.new(name: name, prompt: prompt, output: h['output'],
                  model: h['model'] || default_model, effort: h['effort'] || default_effort,
                  shared: h['shared'] || false, skip_if: h['skip_if'])
      end
    end
  end
end
