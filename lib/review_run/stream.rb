require 'json'

module ReviewRun
  module Stream
    SUB_PREFIX = '  [sub] '.freeze

    def self.parse_line(line)
      s = line.to_s.strip
      return nil if s.empty?
      ev = JSON.parse(s)
      ev.is_a?(Hash) ? ev : nil
    rescue JSON::ParserError
      nil
    end

    def self.format_event(event)
      out = format_body(event)
      return nil if out.nil? || out.empty?
      event['parent_tool_use_id'] ? out.lines.map { |l| SUB_PREFIX + l }.join : out
    end

    def self.format_body(event)
      case event['type']
      when 'system'
        return nil unless event['subtype'] == 'init'
        "== session #{event['session_id']} (#{event['model']})"
      when 'assistant'
        blocks(event).filter_map do |b|
          case b['type']
          when 'text' then b['text'].to_s[0, 2000]
          when 'tool_use' then tool_line(b)
          end
        end.join("\n")
      when 'user'
        blocks(event).filter_map do |b|
          next unless b['type'] == 'tool_result' && b['is_error'] == true
          "!! #{content_text(b['content']).lines.first.to_s.chomp}"
        end.join("\n")
      when 'result'
        format('== result: %s, %d turns, $%.2f, %.1fs', event['subtype'],
               event['num_turns'].to_i, event['total_cost_usd'].to_f,
               event['duration_ms'].to_f / 1000)
      when 'rate_limit_event'
        rl = RateLimit.from_event(event)
        return nil if rl.nil? || rl.status == 'allowed'

        reset = rl.resets_at ? ", resets #{rl.resets_at.strftime('%Y-%m-%d %H:%M')}" : ''
        "== rate limit #{rl.status} (#{rl.type || '?'})#{reset}"
      end
    end

    def self.blocks(event)
      c = event.dig('message', 'content')
      c.is_a?(Array) ? c.select { |b| b.is_a?(Hash) } : []
    end

    def self.content_text(c)
      return c.to_s unless c.is_a?(Array)
      c.map { |x| x.is_a?(Hash) ? x['text'].to_s : x.to_s }.join("\n")
    end

    def self.tool_line(block)
      input = block['input'] || {}
      arg =
        case block['name']
        when 'Bash' then input['command'].to_s[0, 120]
        when 'Read', 'Edit', 'Write' then input['file_path']
        when 'Agent', 'Task' then input['description']
        when 'Grep', 'Glob' then input['pattern']
        end
      "-> #{block['name']}: #{arg}"
    end
  end

  # rate_limit_event of the stream: {"rate_limit_info": {"status", "resetsAt" (epoch s), "rateLimitType"}}
  RateLimit = Struct.new(:status, :resets_at, :type) do
    def self.from_event(event)
      info = event['rate_limit_info']
      return nil unless event['type'] == 'rate_limit_event' && info.is_a?(Hash)

      at = info['resetsAt']
      new(info['status'].to_s, at.is_a?(Numeric) ? Time.at(at.to_i) : nil, info['rateLimitType'])
    end

    def rejected?
      status == 'rejected'
    end
  end

  class Result
    LIMIT_RE = /You've hit your\b.{0,40}?\blimit/
    NOT_LIMIT_RE = /not your usage limit|Context limit/i
    RESET_RE = /resets (?:at )?(?:([A-Z][a-z]{2}) (\d{1,2}), (?:(\d{4}), )?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)/i
    MONTHS = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze
    TOKEN_KEYS = %w[input output cache_read cache_write].freeze
    USAGE_FIELDS = {
      'input' => 'inputTokens',
      'output' => 'outputTokens',
      'cache_read' => 'cacheReadInputTokens',
      'cache_write' => 'cacheCreationInputTokens',
      'cost_usd' => 'costUSD'
    }.freeze

    attr_reader :is_error, :subtype, :text, :cost_usd, :duration_ms,
                :num_turns, :session_id, :models, :tokens

    def self.from_event(event)
      new(event)
    end

    def initialize(event)
      @is_error = event['is_error'] == true
      @subtype = event['subtype']
      @text = event['result'].to_s
      @cost_usd = event['total_cost_usd'].to_f
      @duration_ms = event['duration_ms'].to_i
      @num_turns = event['num_turns'].to_i
      @session_id = event['session_id']
      @models = (event['modelUsage'] || {}).to_h do |name, u|
        [name, USAGE_FIELDS.transform_values { |f| u[f] || 0 }]
      end
      @tokens = TOKEN_KEYS.to_h { |k| [k, @models.values.sum { |m| m[k] }] }
    end

    def limit_hit?
      is_error && text.match?(LIMIT_RE) && !text.match?(NOT_LIMIT_RE)
    end

    # "resets 3pm", "resets 3:30pm", "resets Nov 24, 3pm": next such local time; raises on a bad time
    def limit_reset(now)
      m = text.match(RESET_RE)
      return now + 3600 unless m

      hour = m[4].to_i
      raise ArgumentError, "bad reset hour in #{m[0].inspect}" unless (1..12).cover?(hour)

      hour = hour % 12 + (m[6].casecmp?('pm') ? 12 : 0)
      return clock_reset(now, hour, m[5].to_i) unless m[1]

      month = MONTHS.index(m[1].downcase) or raise ArgumentError, "bad reset month in #{m[0].inspect}"
      t = Time.local(m[3] ? m[3].to_i : now.year, month + 1, m[2].to_i, hour, m[5].to_i)
      t = Time.local(now.year + 1, month + 1, m[2].to_i, hour, m[5].to_i) if t <= now && !m[3]
      t
    end

    private

    def clock_reset(now, hour, min)
      t = Time.local(now.year, now.month, now.day, hour, min)
      t <= now ? t + 86_400 : t
    end
  end
end
