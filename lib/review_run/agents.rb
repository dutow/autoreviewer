require 'zlib'

module ReviewRun
  module Agents
    NAMES = %w[claude codex].freeze
    MODES = %w[claude codex both alternate].freeze
    CODEX_MODEL = 'gpt-6.2-astra'.freeze
    CODEX_EFFORT = 'xhigh'.freeze

    class ConfigError < StandardError; end

    def self.other(agent)
      agent == 'claude' ? 'codex' : 'claude'
    end

    class Config
      attr_reader :mode, :primary

      def self.from_project(config, route:)
        new((config || {})['review'] || {}, route)
      end

      def initialize(review, route)
        @mode = (review['agent'] || 'claude').to_s
        @primary = (review['primary'] || 'claude').to_s
        @claude = review['claude'] || {}
        @codex = review['codex'] || {}
        unless MODES.include?(@mode)
          raise ConfigError, "review.agent: unknown '#{@mode}' (expected #{MODES.join(', ')})"
        end
        unless NAMES.include?(@primary)
          raise ConfigError, "review.primary: unknown '#{@primary}' (expected #{NAMES.join(', ')})"
        end
        if @mode == 'both' && route != 'single'
          raise ConfigError, "review.agent: 'both' needs route single, got '#{route}'"
        end
      end

      def secondary
        Agents.other(primary)
      end

      def model(agent, phase)
        agent == 'codex' ? (@codex['model'] || CODEX_MODEL) : (@claude['model'] || phase.model)
      end

      def effort(agent, phase)
        agent == 'codex' ? (@codex['effort'] || CODEX_EFFORT) : (@claude['effort'] || phase.effort)
      end
    end

    def self.parity(topic)
      digits = topic.to_s[/(\d+)\D*\z/, 1]
      n = digits ? digits.to_i : Zlib.crc32(topic.to_s)
      n.even? ? 'claude' : 'codex'
    end

    def self.pick_alternate(topic:, current:, previous:, paused:)
      start = current || (previous && other(previous)) || parity(topic)
      paused.call(start) && !paused.call(other(start)) ? other(start) : start
    end

    def self.held?(mode, states)
      s = states.values_at('claude', 'codex')
      case mode
      when 'alternate' then s.all? { |x| x != :none }
      when 'both' then s.include?(:short) || s.all?(:long)
      else states[mode] != :none
      end
    end
  end
end
