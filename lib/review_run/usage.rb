require 'json'
require 'fileutils'
require 'time'

module ReviewRun
  class Usage
    TOKEN_KEYS = %w[input output cache_read cache_write].freeze

    # HEAD before the first try of a discovery not done yet
    attr_accessor :discovery_base

    def self.append_log(log_path, entry)
      FileUtils.mkdir_p(File.dirname(log_path))
      File.open(log_path, 'a') { |f| f.puts(JSON.generate(entry)) }
    end

    # no result: claude 0.0 as before, codex unknown
    def self.cost(result, agent)
      return result.cost_usd if result

      agent == 'codex' ? nil : 0.0
    end

    def self.review_agent(path)
      phases = JSON.parse(File.read(path)).fetch('phases')
      last = phases.reverse_each.find { |p| p.is_a?(Hash) && p['status'] == 'ok' }
      last && (last['agent'] || 'claude')
    rescue JSON::ParserError, TypeError, NoMethodError, KeyError, SystemCallError
      nil
    end

    def initialize(path:, route:, claude_version:, out: $stdout, agent_mode: nil)
      @path = path
      @route = route
      @claude_version = claude_version
      @agent_mode = agent_mode
      @codex_version = nil
      @degraded = false
      @discovery_base = nil
      @phases = load(out)
      @changed = false
    end

    def add(phase:, model:, result:, started_at:, agent: 'claude')
      record(entry(phase, model, result, started_at, 'ok', agent))
    end

    def limit(phase:, model:, result:, started_at:, agent: 'claude')
      record(entry(phase, model, result, started_at, 'limit', agent))
    end

    def fail(phase:, reason:, result: nil, started_at:, agent: 'claude')
      record(entry(phase, nil, result, started_at, 'failed', agent).merge('reason' => reason))
    end

    def skip(phase:, agent:, reason:, started_at:)
      record(entry(phase, nil, nil, started_at, 'skipped', agent).merge('reason' => reason, 'cost_usd' => nil))
    end

    def set_version(agent, version)
      agent == 'codex' ? @codex_version = version : @claude_version = version
    end

    def degraded!
      @degraded = true
    end

    def last_agent(phase = nil)
      e = @phases.reverse_each.find { |p| phase.nil? || p['phase'] == phase }
      e && (e['agent'] || 'claude')
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
      costs = @phases.map { |p| p['cost_usd'] }.grep(Numeric)
      h = {
        'schema' => 1,
        'route' => @route,
        'claude_version' => @claude_version
      }
      h['codex_version'] = @codex_version if @codex_version
      h['agent_mode'] = @agent_mode if @agent_mode
      h['degraded'] = true if @degraded
      h['discovery_base'] = @discovery_base if @discovery_base
      h.merge(
        'phases' => @phases,
        'total' => {
          'cost_usd' => costs.empty? ? nil : costs.sum,
          'duration_ms' => @phases.sum { |p| p['duration_ms'].to_i },
          'tokens' => TOKEN_KEYS.to_h { |k| [k, @phases.sum { |p| p['tokens'].is_a?(Hash) ? p['tokens'][k].to_i : 0 }] }
        }
      )
    end

    private

    def load(out)
      return [] unless File.exist?(@path)

      data = JSON.parse(File.read(@path))
      phases = data.fetch('phases', [])
      raise TypeError, 'phases is not a list of objects' unless phases.is_a?(Array) && phases.all?(Hash)

      @agent_mode ||= data['agent_mode']
      @codex_version = data['codex_version']
      @degraded = data['degraded'] == true
      @discovery_base = data['discovery_base'] if data['discovery_base'].is_a?(String)
      phases
    rescue JSON::ParserError, TypeError, NoMethodError, KeyError, SystemCallError => e
      out.puts "WARNING: #{@path} unreadable (#{e.message.lines.first&.strip}), starting fresh"
      []
    end

    def record(e)
      @changed = true
      @phases << e
    end

    def entry(phase, model, result, started_at, status, agent)
      {
        'phase' => phase,
        'agent' => agent,
        'model' => model,
        'started_at' => started_at.iso8601,
        'duration_ms' => result&.duration_ms || 0,
        'num_turns' => result&.num_turns || 0,
        'cost_usd' => Usage.cost(result, agent),
        'session_id' => result&.session_id,
        'status' => status,
        'tokens' => result&.tokens || TOKEN_KEYS.to_h { |k| [k, 0] },
        'models' => result&.models || {}
      }
    end
  end
end
