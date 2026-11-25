require 'json'
require 'time'

require_relative 'usage'

module ReviewRun
  module CodexStream
    def self.format_event(event)
      out = format_body(event)
      out.nil? || out.empty? ? nil : out
    end

    def self.format_body(event)
      case event['type']
      when 'thread.started'
        "== thread #{event['thread_id']}"
      when 'item.started'
        item = event['item'] || {}
        "-> shell: #{item['command'].to_s[0, 120]}" if item['type'] == 'command_execution'
      when 'item.completed'
        format_item(event['item'] || {})
      when 'error'
        "!! #{event['message']}"
      when 'turn.completed'
        u = event['usage'] || {}
        "== result: ok, #{u['input_tokens'].to_i + u['output_tokens'].to_i} tokens"
      when 'turn.failed'
        "== result: failed: #{event.dig('error', 'message')}"
      end
    end

    def self.format_item(item)
      case item['type']
      when 'agent_message'
        item['text'].to_s[0, 2000]
      when 'command_execution'
        code = item['exit_code']
        "!! exit #{code}" if code.is_a?(Integer) && code != 0
      when 'file_change'
        paths = Array(item['changes']).filter_map { |c| c['path'] if c.is_a?(Hash) }
        "-> edit: #{paths.join(', ')}"
      when 'error'
        "!! #{item['message']}"
      end
    end
  end

  class CodexResult
    NOT_LIMIT_RE = /context/i
    LIMIT_RE = /usage limit/i
    AT_RE = /try again at (.+?)(?:\.(?:\s|\z)|\z)/mi
    IN_RE = /try again in (\d+)\s*(minute|hour|day)s?/i
    UNITS = { 'minute' => 60, 'hour' => 3600, 'day' => 86_400 }.freeze
    TIME_ONLY_RE = /\A\d{1,2}(?::\d{2}){0,2}\s*(?:am|pm)?\z/i

    attr_reader :is_error, :subtype, :text, :cost_usd, :duration_ms,
                :num_turns, :session_id, :models, :tokens

    def initialize(events, model:, duration_ms:)
      @duration_ms = duration_ms
      @cost_usd = nil
      @session_id = events.reverse_each.filter_map { |e| e['thread_id'] if e['type'] == 'thread.started' }.first
      @num_turns = events.count { |e| e['type'] == 'item.completed' }
      @tokens = sum_tokens(events)
      @models = { model => @tokens.merge('cost_usd' => nil) }
      failed = events.select { |e| e['type'] == 'turn.failed' }
      @is_error = !failed.empty? || events.none? { |e| e['type'] == 'turn.completed' }
      @subtype = @is_error ? 'error' : 'success'
      @text = final_text(events, failed)
    end

    def limit_hit?
      is_error && text.match?(LIMIT_RE) && !text.match?(NOT_LIMIT_RE)
    end

    def limit_reset(now)
      if (m = text.match(AT_RE))
        t = parse_at(m[1].strip, now)
        return t if t
      elsif (m = text.match(IN_RE))
        return now + (m[1].to_i * UNITS[m[2].downcase])
      end
      now + 3600
    end

    private

    def sum_tokens(events)
      sums = Usage::TOKEN_KEYS.to_h { |k| [k, 0] }
      events.each do |e|
        next unless e['type'] == 'turn.completed' && e['usage'].is_a?(Hash)

        u = e['usage']
        cached = u['cached_input_tokens'].to_i
        sums['input'] += u['input_tokens'].to_i - cached
        sums['cache_read'] += cached
        sums['cache_write'] += u['cache_write_input_tokens'].to_i
        sums['output'] += u['output_tokens'].to_i
      end
      sums
    end

    def final_text(events, failed)
      msg = failed.last&.dig('error', 'message')
      msg ||= events.reverse_each.find { |e| e['type'] == 'error' }&.dig('message')
      msg ||= events.reverse_each.filter_map do |e|
        e.dig('item', 'text') if e['type'] == 'item.completed' && e.dig('item', 'type') == 'agent_message'
      end.first
      msg.to_s
    end

    def parse_at(str, now)
      s = str.gsub(/(\d)(?:st|nd|rd|th)\b/i, '\1')
      t = Time.parse(s, now)
      t += 86_400 if t <= now && s.match?(TIME_ONLY_RE)
      t
    rescue ArgumentError
      nil
    end
  end
end
