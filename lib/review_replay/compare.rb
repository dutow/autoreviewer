require 'json'
require 'fileutils'

require_relative 'workspace'
require_relative '../review_run/session'
require_relative '../review_run/usage'

module ReviewReplay
  # one claude session matching the postable points of a replay against a reference review
  module Compare
    Side = Struct.new(:label, :findings_dir, :run_dir, keyword_init: true)

    LISTS = { 'matched' => %w[replay reference reason],
              'only_reference' => %w[point level reason],
              'only_replay' => %w[point level reason] }.freeze
    PROMPT = File.join(__dir__, 'compare-prompt.md')

    module_function

    def resolve(dir)
      dir = File.expand_path(dir)
      if File.file?(File.join(dir, 'replay.json'))
        return Side.new(label: File.basename(dir), findings_dir: File.realpath(File.join(dir, 'findings')), run_dir: dir)
      end
      return Side.new(label: 'reference', findings_dir: dir, run_dir: nil) if File.file?(File.join(dir, '05-summary.md'))

      raise ReplayError, "#{dir}: not a replay run or a finished review"
    rescue SystemCallError => e
      raise ReplayError, "#{dir}: #{e.message}"
    end

    def usage_totals(findings_dir)
      path = File.join(findings_dir, 'usage.json')
      return nil unless File.file?(path)

      phases = JSON.parse(File.read(path))['phases'] || []
      costs = phases.filter_map { |p| p['cost_usd'] if p['cost_usd'].is_a?(Numeric) }
      tokens = ReviewRun::Usage::TOKEN_KEYS.to_h { |k| [k, phases.sum { |p| p.dig('tokens', k).to_i }] }
      { 'cost_usd' => costs.empty? ? nil : costs.sum.round(4), 'tokens' => tokens,
        'phases' => phases.map { |p| p.slice('phase', 'model', 'status', 'cost_usd') } }
    rescue JSON::ParserError
      nil
    end

    def prompt(replay:, reference:, md:, json:)
      File.read(PROMPT).gsub('$REPLAY') { replay }.gsub('$REFERENCE') { reference }
          .gsub('$MD') { md }.gsub('$JSON') { json }
    end

    def check(data)
      return ['not a JSON object'] unless data.is_a?(Hash)

      LISTS.flat_map do |key, fields|
        list = data[key]
        next ["#{key}: not a list"] unless list.is_a?(Array)

        list.each_with_index.filter_map do |item, i|
          missing = item.is_a?(Hash) ? fields.reject { |f| item[f].is_a?(String) } : fields
          "#{key}[#{i}]: missing #{missing.join(', ')}" unless missing.empty?
        end
      end
    end

    # -> true on success; prints the result to out
    def run(replay_dir:, reference_dir:, claude_bin:, out: $stdout)
      a = resolve(replay_dir)
      raise ReplayError, "#{File.expand_path(replay_dir)}: not a replay run" unless a.run_dir

      b = resolve(reference_dir)
      check_pair(a, b)
      md = File.join(a.run_dir, "compare-#{b.label}.md")
      json = File.join(a.run_dir, "compare-#{b.label}.json")
      FileUtils.rm_f([md, json])
      log = File.join(a.run_dir, 'state', 'logs', "compare-#{b.label}.jsonl")
      session = ReviewRun::Session.new(claude_bin: claude_bin, workspace_dir: a.run_dir, out: out)
      result, status, = session.run(prompt(replay: a.findings_dir, reference: b.findings_dir, md: md, json: json),
                                    model: 'opus', effort: nil, log: log)
      unless result && !result.is_error && status&.success?
        out.puts "ERROR: compare session failed (#{result ? result.text.to_s[0, 300] : 'no result'})"
        return false
      end

      data, why = load(json)
      if why
        out.puts "ERROR: #{json}: invalid (#{why})"
        return false
      end

      data['counts'] = LISTS.keys.to_h { |k| [k, data[k].size] }
      data['usage'] = { 'replay' => usage_totals(a.findings_dir), 'reference' => usage_totals(b.findings_dir) }
      data['compare_cost_usd'] = result.cost_usd
      File.write(json, "#{JSON.pretty_generate(data)}\n")
      c = data['counts']
      out.puts "matched #{c['matched']}, only in reference #{c['only_reference']}, only in replay #{c['only_replay']}"
      out.puts "cost replay #{money(data, 'replay')} vs reference #{money(data, 'reference')}"
      out.puts "report: #{md}"
      true
    end

    # same project/topic/version on both sides, and a replay that got as far as a summary
    def check_pair(a, b)
      raise ReplayError, "#{a.run_dir}: replay has no 05-summary.md" unless File.file?(File.join(a.findings_dir, '05-summary.md'))

      meta = run_meta(a.run_dir)
      if b.run_dir
        other = run_meta(b.run_dir)
        keys = %w[project topic version]
        return if other.values_at(*keys) == meta.values_at(*keys)

        raise ReplayError, "#{b.run_dir} replays #{desc(other)}, #{a.run_dir} replays #{desc(meta)}"
      elsif meta['reference'] && real(b.findings_dir) != real(meta['reference'])
        raise ReplayError, "#{b.findings_dir} is not the reference of #{a.run_dir} (#{meta['reference']})"
      end
    end

    def run_meta(run_dir)
      JSON.parse(File.read(File.join(run_dir, 'replay.json')))
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def desc(meta)
      "#{meta['project']}/#{meta['topic']} v#{meta['version']}"
    end

    def real(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end

    def load(json)
      return [nil, 'missing'] unless File.file?(json)

      data = JSON.parse(File.read(json))
      errs = check(data)
      errs.empty? ? [data, nil] : [nil, errs.join('; ')]
    rescue JSON::ParserError => e
      [nil, e.message.lines.first.strip]
    end

    def table(root)
      Dir.glob(File.join(root, '*', '*', '*', 'compare-*.json')).sort.map do |path|
        project, topic, run = path.split('/')[-4..-2]
        label = File.basename(path, '.json').delete_prefix('compare-')
        data = JSON.parse(File.read(path))
        c = data['counts']
        next "#{project}/#{topic} #{run} vs #{label}: invalid compare (no counts)" unless c.is_a?(Hash)

        meta = run_meta(File.dirname(path))
        flags = []
        flags << ' [replay failed]' if meta['ok'] == false
        flags << ' [inputs changed]' if meta['inputs_changed']
        "#{project}/#{topic} #{run} vs #{label}: matched #{c['matched']}, only-ref #{c['only_reference']}, " \
          "only-replay #{c['only_replay']}, cost #{money(data, 'replay')} vs #{money(data, 'reference')}#{flags.join}"
      rescue JSON::ParserError
        "#{project}/#{topic} #{run} vs #{label}: unreadable"
      end
    end

    def money(data, side)
      v = data.dig('usage', side, 'cost_usd')
      v ? format('$%.2f', v) : 'n/a'
    end
  end
end
