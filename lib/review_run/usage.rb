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

    def initialize(path:, route:, claude_version:, out: $stdout)
      @path = path
      @route = route
      @claude_version = claude_version
      @phases = load(out)
      @changed = false
    end

    def add(phase:, model:, result:, started_at:)
      record(entry(phase, model, result, started_at, 'ok'))
    end

    def limit(phase:, model:, result:, started_at:)
      record(entry(phase, model, result, started_at, 'limit'))
    end

    def fail(phase:, reason:, result: nil, started_at:)
      record(entry(phase, nil, result, started_at, 'failed').merge('reason' => reason))
    end

    def last_status(phase)
      @phases.reverse_each.find { |p| p['phase'] == phase }&.fetch('status', nil)
    end

    # true once a phase was recorded by this instance
    def changed?
      @changed
    end

    def write
      FileUtils.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate(to_h) + "\n")
      File.rename(tmp, @path)
    end

    def to_h
      {
        'schema' => 1,
        'route' => @route,
        'claude_version' => @claude_version,
        'phases' => @phases,
        'total' => {
          'cost_usd' => @phases.sum { |p| p['cost_usd'].to_f },
          'duration_ms' => @phases.sum { |p| p['duration_ms'].to_i },
          'tokens' => TOKEN_KEYS.to_h { |k| [k, @phases.sum { |p| p['tokens'].is_a?(Hash) ? p['tokens'][k].to_i : 0 }] }
        }
      }
    end

    private

    def load(out)
      return [] unless File.exist?(@path)

      phases = JSON.parse(File.read(@path)).fetch('phases', [])
      raise TypeError, 'phases is not a list of objects' unless phases.is_a?(Array) && phases.all?(Hash)

      phases
    rescue JSON::ParserError, TypeError, NoMethodError, KeyError, SystemCallError => e
      out.puts "WARNING: #{@path} unreadable (#{e.message.lines.first&.strip}), starting fresh"
      []
    end

    def record(e)
      @changed = true
      @phases << e
    end

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
