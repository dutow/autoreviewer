require 'json'
require 'fileutils'
require 'time'

module ReviewRun
  class Usage
    TOKEN_KEYS = %w[input output cache_read cache_write].freeze

    def self.append_log(log_path, entry)
      FileUtils.mkdir_p(File.dirname(log_path))
      File.open(log_path, 'a') { |f| f.puts(JSON.generate(entry)) }
    end

    def initialize(path:, route:, claude_version:)
      @path = path
      @route = route
      @claude_version = claude_version
      @phases = File.exist?(path) ? JSON.parse(File.read(path)).fetch('phases', []) : []
    end

    def add(phase:, model:, result:, started_at:)
      @phases << entry(phase, model, result, started_at, 'ok')
    end

    def fail(phase:, reason:, result: nil, started_at:)
      @phases << entry(phase, nil, result, started_at, 'failed').merge('reason' => reason)
    end

    def last_status(phase)
      @phases.reverse_each.find { |p| p['phase'] == phase }&.fetch('status', nil)
    end

    def write
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(to_h) + "\n")
    end

    def to_h
      {
        'schema' => 1,
        'route' => @route,
        'claude_version' => @claude_version,
        'phases' => @phases,
        'total' => {
          'cost_usd' => @phases.sum { |p| p['cost_usd'] },
          'duration_ms' => @phases.sum { |p| p['duration_ms'] },
          'tokens' => TOKEN_KEYS.to_h { |k| [k, @phases.sum { |p| p['tokens'][k] }] }
        }
      }
    end

    private

    def entry(phase, model, result, started_at, status)
      {
        'phase' => phase,
        'model' => model,
        'started_at' => started_at.iso8601,
        'duration_ms' => result&.duration_ms || 0,
        'num_turns' => result&.num_turns || 0,
        'cost_usd' => result&.cost_usd || 0.0,
        'session_id' => result&.session_id,
        'status' => status,
        'tokens' => result&.tokens || TOKEN_KEYS.to_h { |k| [k, 0] },
        'models' => result&.models || {}
      }
    end
  end
end
