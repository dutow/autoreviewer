require 'open3'
require 'fileutils'
require 'json'
require 'yaml'
require 'shellwords'
require 'time'

require_relative 'manifest'
require_relative 'prompt'
require_relative 'usage'
require_relative 'findings_dir'
require_relative 'session'
require_relative 'codex_session'
require_relative 'pause'
require_relative 'agents'

module ReviewRun
  class RunError < StandardError; end

  class Runner
    GIT_RETRIES = 5
    GIT_RETRY_WAIT = 2
    LIMIT_RETRIES = 5
    LIMIT_GRACE = 120
    LIMIT_FALLBACK_WAIT = 3600
    LIMIT_MIN_WAIT = 300
    CHILD_ENV = Session::CHILD_ENV
    API_KEY_WARNING = 'WARNING: ANTHROPIC_API_KEY is set; claude -p will bill the API key'.freeze
    CODEX_KEY_WARNING = 'WARNING: OPENAI_API_KEY/CODEX_API_KEY is set; codex exec may bill the API key'.freeze
    DISCOVERY = 'discovery'.freeze
    DISCOVERY_OUTPUT = '02-code-review.md'.freeze
    DISCOVERY_SKIP = 'usage limit (long)'.freeze

    # agent: the one running now, phases run on it; a usage limit may switch it
    Review = Struct.new(:project, :topic, :version, :route, :yaml, :manifest, :phases,
                        :outdir, :prev_dir, :window, :agents, :agent, keyword_init: true)
    CommitPhase = Struct.new(:name, :model, :effort)

    # agent: force one agent for every run, no switching
    def initialize(base_dir:, workspace_dir:, state_dir:, claude_bin: 'claude', codex_bin: 'codex', agent: nil,
                   out: $stdout, sleeper: ->(s) { sleep s }, clock: -> { Time.now }, replay: false)
      raise ArgumentError, "unknown agent #{agent.inspect}" if agent && !Agents::NAMES.include?(agent)

      @replay = replay
      @base_dir = base_dir
      @workspace_dir = workspace_dir
      @state_dir = state_dir
      @forced = agent
      @bins = { 'claude' => claude_bin, 'codex' => codex_bin }
      @out = out
      @sleeper = sleeper
      @clock = clock
      @sessions = {
        'claude' => Session.new(claude_bin: claude_bin, workspace_dir: workspace_dir, out: out),
        'codex' => CodexSession.new(codex_bin: codex_bin, workspace_dir: workspace_dir, out: out)
      }
      @versions = {}
      @pauses = Agents::NAMES.to_h { |a| [a, Pause.for(state_dir, a)] }
    end

    def run_topic(project:, topic:, route: nil)
      warn_api_key
      rv = load_review(project, topic, route)
      rv.phases = both_phases(rv) if both?(rv)
      warn_codex_key(rv)
      rel = FindingsDir.prepare(base_dir: @base_dir, project_dir: project_dir(project), topic: topic)
      raise RunError, 'could not prepare findings dir' unless rel

      rv.outdir = File.join(project, rel)
      outdir_abs = File.join(@workspace_dir, rv.outdir)
      usage = Usage.new(path: File.join(outdir_abs, 'usage.json'), route: rv.route,
                        claude_version: version('claude'), out: @out, agent_mode: rv.agents.mode)
      rv.agent = pick_agent(rv, usage)
      say "=== review #{project}/#{topic} v#{rv.version}, route #{rv.route}, #{rv.phases.size} phases, " \
          "#{agent_desc(rv)}"

      rv.phases.each_with_index do |phase, idx|
        if (why = skip_reason(rv, phase, outdir_abs, usage))
          say "skip #{phase.name}: #{why}"
          next if commit_output(rv, phase)

          return fail_review(project, topic, "could not commit #{File.join(rv.outdir, phase.output)}")
        end
        return false unless run_phase(rv, phase, idx, usage)
      end
      finish(rv, usage)
    rescue StandardError => e
      msg = e.is_a?(RunError) || e.is_a?(ManifestError) ? e.message : "#{e.class}: #{e.message} (#{e.backtrace&.first})"
      fail_review(project, topic, msg)
    end

    def run_commits(project:, range:)
      warn_api_key
      from, to = range.split('..', 2)
      raise RunError, "bad range #{range.inspect}, expected FROM..TO" if from.to_s.empty? || to.to_s.empty?

      window = "#{project}-commits-#{from[0, 7]}-#{to[0, 7]}"
      rv = Review.new(project: project, topic: range, version: nil, route: 'commits', window: window,
                      agents: Agents::Config.from_project({}, route: 'commits'), agent: 'claude')
      phase = CommitPhase.new('commits', 'opus', nil)
      prompt = Prompt.render_command(path: commit_command_path(project), args: range)
      log = File.join(@state_dir, 'logs', window, 'commits.jsonl')
      say "=== commit review #{project} #{range}, model opus"
      _started, result, status, reason = run_past_limit(rv, phase, log) { prompt }
      reason ||= session_failure(rv.agent, result, status)
      log_usage(rv, phase, reason ? 'failed' : 'ok', result)
      return fail_review(project, window.delete_prefix("#{project}-"), reason) if reason

      say "=== commit review #{project} #{range} done"
      true
    rescue StandardError => e
      msg = e.is_a?(RunError) ? e.message : "#{e.class}: #{e.message} (#{e.backtrace&.first})"
      fail_review(project, 'commits', msg)
    end

    def render(project:, topic:, phase:, route: nil)
      rv = load_review(project, topic, route, use_mode: false)
      idx = rv.phases.index { |p| p.name == phase }
      raise RunError, "phase #{phase} not in route #{rv.route}" unless idx

      Prompt.render(manifest: rv.manifest, phase: rv.phases[idx], ctx: context(rv, idx))
    end

    private

    def project_dir(project)
      File.join(@workspace_dir, project)
    end

    def load_review(project, topic, route, use_mode: true)
      yaml = File.join(project_dir(project), 'project.yaml')
      raise RunError, "project.yaml not found: #{yaml}" unless File.exist?(yaml)

      config = YAML.safe_load_file(yaml) || {}
      family = config.dig('review', 'phases')
      raise RunError, "#{yaml}: review.phases not set" if family.to_s.empty?

      route ||= config.dig('review', 'route') || 'full'
      mpath = File.join(@workspace_dir, '.claude', 'review-phases', family, 'phases.yaml')
      raise RunError, "phase manifest not found: #{mpath}" unless File.exist?(mpath)

      begin
        # route rule of the mode only when the mode runs: not forced, not rendered
        agents = Agents::Config.from_project(config, route: use_mode && !@forced ? route : nil)
      rescue Agents::ConfigError => e
        raise RunError, "#{yaml}: #{e.message}"
      end
      manifest = Manifest.load(mpath)
      meta = File.join(project_dir(project), 'review', topic, 'metadata.json')
      raise RunError, "#{meta} not found" unless File.exist?(meta)

      version = JSON.parse(File.read(meta))['version']
      raise RunError, "version missing in #{meta}" if version.nil?

      prev = FindingsDir.previous_version(project_dir: project_dir(project), topic: topic, version: version)
      Review.new(project: project, topic: topic, version: version, route: route, yaml: yaml,
                 manifest: manifest, phases: manifest.route(route),
                 outdir: File.join(project, 'findings', topic, "v#{version}"), window: "#{project}-#{topic}",
                 prev_dir: prev && File.join(project, prev), agents: agents)
    end

    def pick_agent(rv, usage)
      return @forced if @forced

      mode = rv.agents.mode
      return mode if Agents::NAMES.include?(mode)
      return rv.agents.primary unless mode == 'alternate'

      now = @clock.call
      prev = rv.prev_dir && (Usage.review_agent(File.join(@workspace_dir, rv.prev_dir, 'usage.json')) || 'claude')
      Agents.pick_alternate(topic: rv.topic, current: usage.last_agent, previous: prev,
                            paused: ->(a) { @pauses[a].active?(now) })
    end

    def agent_desc(rv)
      desc = rv.agents.mode
      desc += ', forced' if @forced
      desc += ", discovery on #{rv.agents.secondary}" if both?(rv)
      if switchable?(rv)
        now = @clock.call
        paused = Agents::NAMES.select { |a| @pauses[a].active?(now) }
        desc += ", #{paused.join(' and ')} paused" unless paused.empty?
      end
      "agent #{rv.agent} (#{desc})"
    end

    def switchable?(rv)
      !@forced && rv.agents.mode == 'alternate'
    end

    def single_agent?(rv)
      @forced || Agents::NAMES.include?(rv.agents.mode)
    end

    def commit_command_path(project)
      yaml = File.join(project_dir(project), 'project.yaml')
      raise RunError, "project.yaml not found: #{yaml}" unless File.exist?(yaml)

      command = (YAML.safe_load_file(yaml) || {}).dig('commit_review', 'command')
      raise RunError, "#{yaml}: commit_review.command not set" if command.to_s.empty?

      ns, name = command.split(':', 2)
      raise RunError, "commit_review.command #{command.inspect} is not <ns>:<name>" if name.to_s.empty?

      path = File.join(@workspace_dir, '.claude', 'commands', ns, "#{name}.md")
      raise RunError, "command file not found: #{path}" unless File.exist?(path)

      path
    end

    def session_failure(agent, result, status)
      return "no result event (#{exit_desc(status, agent)})" unless result
      return "#{agent} error (#{result.subtype}): #{result.text[0, 300]}" if result.is_error
      return "#{agent} #{exit_desc(status, agent)}" unless status&.success?

      nil
    end

    def context(rv, idx)
      Context.new(project: rv.project, topic: rv.topic, version: "v#{rv.version}", outdir: rv.outdir,
                  prev_dir: rv.prev_dir, index: idx + 1, total: rv.phases.size, replay: @replay)
    end

    # resume: phase skipped before, or output present and last run of the phase was not cut short;
    # discovery also when the route phase is done, unless a discovery try is pending: its guard must run
    def skip_reason(rv, phase, outdir_abs, usage)
      if discovery?(rv, phase) && !usage.discovery_base && (why = skip_reason(rv, rv.phases.last, outdir_abs, usage))
        return "#{rv.phases.last.name}: #{why}"
      end
      return 'skipped earlier' if usage.last_status(phase.name) == 'skipped'

      if phase.output && File.exist?(File.join(outdir_abs, phase.output)) &&
         !%w[failed limit].include?(usage.last_status(phase.name))
        return "#{phase.output} exists"
      end

      'skip_if matched' if phase.skip?(outdir_abs)
    end

    def commit_output(rv, phase)
      if discovery?(rv, phase)
        return commit([discovery_dir(rv)], "review(#{rv.topic}): #{rv.agents.secondary} discovery (runner)")
      end
      return true unless phase.output

      commit([File.join(rv.outdir, phase.output)], "review(#{rv.topic}): #{phase.name} output (runner)")
    end

    def run_phase(rv, phase, idx, usage)
      discovery = discovery?(rv, phase)
      rv.agent = discovery ? rv.agents.secondary : rv.agents.primary if both?(rv)
      log = File.join(@state_dir, 'logs', "#{rv.window}-v#{rv.version}", format('%02d-%s.jsonl', idx + 1, phase.name))
      effort = rv.agents.effort(rv.agent, phase)
      say "=== phase #{phase.name} (#{idx + 1} of #{rv.phases.size}), agent #{rv.agent}, " \
          "model #{rv.agents.model(rv.agent, phase)}#{", effort #{effort}" if effort}"
      base = discovery_base(rv, usage) if discovery
      started, result, status, reason = run_past_limit(rv, phase, log, usage) do
        seed_discussion(rv) if discovery && @replay
        Prompt.render(manifest: rv.manifest, phase: phase, ctx: phase_context(rv, phase, idx, usage))
      end
      stray = discovery_guard(rv, base, usage.discovery_dirty.to_a) if discovery
      return skip_discovery(rv, phase, usage) if reason == DISCOVERY_SKIP && !stray

      reason = stray || reason || phase_failure(rv, phase, result, status)
      log_usage(rv, phase, reason ? 'failed' : 'ok', result)
      if reason
        usage.fail(phase: phase.name, reason: reason, result: result, started_at: started, agent: rv.agent)
        save_usage(rv, usage)
        fail_review(rv.project, rv.topic, "phase #{phase.name}: #{reason}")
        return false
      end
      usage.discovery_base = nil if discovery
      usage.add(phase: phase.name, model: rv.agents.model(rv.agent, phase), result: result, started_at: started,
                agent: rv.agent)
      usage.write
      true
    end

    def phase_failure(rv, phase, result, status)
      reason = session_failure(rv.agent, result, status)
      return reason if reason || !phase.output

      file = File.join(rv.outdir, phase.output)
      return "output #{file} missing" unless File.exist?(File.join(@workspace_dir, file))

      commit_output(rv, phase) ? nil : "could not commit #{file}"
    end

    def exit_desc(status, agent)
      return "#{agent} did not start" unless status

      status.exited? ? "exit #{status.exitstatus}" : status.to_s
    end

    # usage limit: pause the agent, then switch (alternate) or wait for the reset and re-run;
    # reason set once retries run out. The block gives the prompt for the agent of each try.
    def run_past_limit(rv, phase, log, usage = nil)
      hits = 0
      notified = false
      loop do
        return [@clock.call, nil, nil, DISCOVERY_SKIP] unless both_pick(rv, phase, usage)

        pause = @pauses[rv.agent]
        started = @clock.call
        result, status, rate_limit = run_session(rv, phase, yield, log, usage)
        unless limit_hit?(result, status, rate_limit)
          pause.clear if hits.positive? && pause.by == rv.window
          return [started, result, status, nil]
        end

        hits += 1
        until_t = limit_until(result, rate_limit)
        pause.set(until_t, by: rv.window)
        return [started, result, status, 'usage limit, retries exhausted'] if hits > LIMIT_RETRIES

        log_usage(rv, phase, 'limit', result)
        if usage
          usage.limit(phase: phase.name, model: rv.agents.model(rv.agent, phase), result: result,
                      started_at: started, agent: rv.agent)
          usage.write
        end
        next if switch_agent(rv) || both_long_limit?(rv, phase, until_t)

        notified ||= notify_long_limit(rv, until_t)
        wait_for_reset(rv, phase, until_t, hits)
      end
    end

    def switch_agent(rv)
      other = Agents.other(rv.agent)
      return false unless switchable?(rv) && !@pauses[other].active?(@clock.call)

      say "usage limit on #{rv.agent}, switching to #{other}"
      rv.agent = other
      true
    end

    # alternate with both paused: wait for the earlier reset and go on with that agent
    def wait_for_reset(rv, phase, until_t, hits)
      say "#{rv.agent} usage limit in phase #{phase.name}, paused until #{fmt_time(until_t)} " \
          "(retry #{hits}/#{LIMIT_RETRIES})"
      other = Agents.other(rv.agent)
      other_t = switchable?(rv) && @pauses[other].until_time
      if other_t && other_t < until_t
        say "#{other} paused until #{fmt_time(other_t)}, waiting for #{other}"
        rv.agent = other
        until_t = other_t
      end
      @sleeper.call([(until_t - @clock.call).ceil, 0].max)
    end

    def notify_long_limit(rv, until_t)
      return false unless single_agent?(rv) && until_t - @clock.call > Pause::LONG

      notify("LIMIT-#{rv.agent}", "#{rv.agent} usage limit until #{fmt_time(until_t)}")
      true
    end

    def fmt_time(t)
      t.strftime('%Y-%m-%d %H:%M:%S')
    end

    # rejected rate_limit_event, unless the run still ended clean (e.g. carried by overage)
    def limit_hit?(result, status, rate_limit)
      return result&.limit_hit? || false unless rate_limit

      clean = result && !result.is_error && status&.success?
      !clean
    end

    def limit_until(result, rate_limit)
      now = @clock.call
      reset = begin
        rate_limit&.resets_at || (result ? result.limit_reset(now) : now + LIMIT_FALLBACK_WAIT)
      rescue StandardError
        now + LIMIT_FALLBACK_WAIT
      end
      [reset + LIMIT_GRACE, now + LIMIT_MIN_WAIT].max
    end

    def run_session(rv, phase, prompt, log, usage)
      agent = rv.agent
      ret = @sessions[agent].run(prompt, model: rv.agents.model(agent, phase), effort: rv.agents.effort(agent, phase),
                                         log: log)
      usage&.set_version(agent, version(agent))
      ret
    rescue SystemCallError => e
      say "ERROR: could not run #{@bins[agent]}: #{e.message}"
      [nil, nil, nil]
    end

    def version(agent)
      @versions[agent] ||= @sessions[agent].version
    end

    # both: the route's one phase runs twice, as discovery on the secondary into
    # <outdir>/<secondary>/, then as itself on the primary

    def both?(rv)
      !@forced && rv.agents.mode == 'both'
    end

    def discovery?(rv, phase)
      both?(rv) && phase.name == DISCOVERY
    end

    def discovery_dir(rv)
      File.join(rv.outdir, rv.agents.secondary)
    end

    def both_phases(rv)
      raise RunError, 'review.agent both needs a one-phase route' unless rv.phases.size == 1

      ph = rv.phases.first
      [Phase.new(**ph.to_h.merge(name: DISCOVERY, output: "#{rv.agents.secondary}/#{DISCOVERY_OUTPUT}")), ph]
    end

    # each both session runs the whole one-phase prompt, so the header says 1 of 1
    def phase_context(rv, phase, idx, usage)
      ctx = context(rv, idx)
      return ctx unless both?(rv)

      ctx.index = ctx.total = 1
      if phase.name == DISCOVERY
        ctx.outdir = discovery_dir(rv)
        ctx.note = Prompt::DISCOVERY_NOTE
      elsif rv.agent == rv.agents.primary && discovered?(rv, usage)
        ctx.note = Prompt.primary_note(discovery_dir(rv))
      end
      ctx
    end

    def discovered?(rv, usage)
      usage.last_status(DISCOVERY) != 'skipped' &&
        File.exist?(File.join(@workspace_dir, discovery_dir(rv), DISCOVERY_OUTPUT))
    end

    # sets the agent before each try; false: skip discovery, the secondary is long-limited.
    # The review runs on the primary unless it is long-limited, then on the other one;
    # both long-limited: wait for the earlier reset.
    def both_pick(rv, phase, usage)
      return true unless both?(rv)

      now = @clock.call
      return !@pauses[rv.agent].long?(now) if phase.name == DISCOVERY

      primary = rv.agents.primary
      other = rv.agents.secondary
      agent = [primary, other].find { |a| !@pauses[a].long?(now) } || wait_for_earlier(primary, other, now)
      if agent == other && rv.agent != other
        say "primary #{primary} long-limited, review runs on #{other} alone"
        usage.degraded!
      end
      rv.agent = agent
      true
    end

    # not waited out: both_pick degrades on the next try
    def both_long_limit?(rv, phase, until_t)
      return false unless both?(rv) && until_t - @clock.call > Pause::LONG

      say "#{rv.agent} usage limit in phase #{phase.name}, paused until #{fmt_time(until_t)}"
      true
    end

    def wait_for_earlier(primary, other, now)
      agent, t = [primary, other].map { |a| [a, @pauses[a].until_time || now] }.min_by(&:last)
      say "#{primary} and #{other} long-limited, waiting for #{agent} until #{fmt_time(t)}"
      @sleeper.call([(t - now).ceil, 0].max)
      agent
    end

    def skip_discovery(rv, phase, usage)
      t = @pauses[rv.agent].until_time
      say "#{rv.agent} long-limited#{" until #{fmt_time(t)}" if t}, discovery skipped"
      usage.skip(phase: phase.name, agent: rv.agent, reason: DISCOVERY_SKIP, started_at: @clock.call)
      usage.discovery_base = nil
      usage.degraded!
      usage.write
      return true if commit_output(rv, phase)

      fail_review(rv.project, rv.topic, "could not commit #{discovery_dir(rv)}")
    end

    # replay: the discussion as of the original review, where discovery looks for it
    def seed_discussion(rv)
      src = File.join(@workspace_dir, rv.outdir, 'discussion.txt')
      dst = File.join(@workspace_dir, discovery_dir(rv), 'discussion.txt')
      return if !File.file?(src) || File.exist?(dst)

      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp(src, dst)
    end

    # kept in usage.json until discovery is done, so a resumed discovery still sees
    # strays committed by an earlier try; so are the paths dirty before the first try
    def discovery_base(rv, usage)
      base = usage.discovery_base
      if base && !git('cat-file', '-e', "#{base}^{commit}").first
        say "WARNING: discovery base #{base[0, 12]} not in history, guard starts from HEAD"
        base = nil
      end
      unless usage.discovery_base
        dirty = dirty_paths(rv)
        raise RunError, 'git status failed' unless dirty

        usage.discovery_dirty = outside_discovery(rv, dirty)
      end
      usage.discovery_base = base || head
      usage.write
      usage.discovery_base
    end

    # runs on every discovery exit: changes under outdir since base (committed, staged, untracked)
    # outside the discovery subdir; no revert, the agent may have committed them
    def discovery_guard(rv, base, dirty_before)
      ok, committed = git('diff', '--name-only', '--no-renames', '-z', base, 'HEAD', '--', rv.outdir,
                          stdout_only: true)
      status = dirty_paths(rv)
      return 'discovery guard: git failed' unless ok && status

      stray = outside_discovery(rv, committed.split("\0") + status) - dirty_before
      "discovery wrote outside #{discovery_dir(rv)}: #{stray.join(', ')}" unless stray.empty?
    end

    # staged, modified or untracked under outdir; false when git fails
    def dirty_paths(rv)
      ok, status = git('status', '--porcelain', '--no-renames', '-z', '--untracked-files=all', '--', rv.outdir,
                       stdout_only: true)
      ok && status.split("\0").map { |e| e[3..] }
    end

    def outside_discovery(rv, paths)
      own = "#{discovery_dir(rv)}/"
      exempt = %w[metadata.json usage.json].map { |f| File.join(rv.outdir, f) }
      paths.uniq.reject { |f| f.start_with?(own) || exempt.include?(f) }
    end

    def head
      ok, out = git('rev-parse', 'HEAD', stdout_only: true)
      raise RunError, 'git rev-parse HEAD failed' unless ok

      out.strip
    end

    def finish(rv, usage)
      run_findings_metadata(rv)
      return fail_review(rv.project, rv.topic, 'could not commit usage.json') unless save_usage(rv, usage)

      say "=== review #{rv.project}/#{rv.topic} done"
      true
    end

    # usage.json only when this run recorded a phase: a re-run of a finished review leaves none behind
    def save_usage(rv, usage)
      meta = File.join(rv.outdir, 'metadata.json')
      return commit([meta], "review(#{rv.topic}): update metadata") unless usage.changed?

      usage.write
      commit([File.join(rv.outdir, 'usage.json'), meta], "review(#{rv.topic}): add usage")
    end

    def run_findings_metadata(rv)
      out, st = Open3.capture2e(File.join(@base_dir, 'bin', 'findings-metadata'), '--project', rv.yaml, rv.topic)
      out.each_line { |l| @out.print "  #{l}" }
      say 'WARNING: findings-metadata failed (continuing)' unless st.success?
    rescue SystemCallError => e
      say "WARNING: findings-metadata: #{e.message}"
    end

    def log_usage(rv, phase, status, result)
      Usage.append_log(File.join(@state_dir, 'usage.log'), {
                         'time' => @clock.call.iso8601, 'project' => rv.project, 'topic' => rv.topic,
                         'version' => rv.version, 'route' => rv.route, 'phase' => phase.name, 'agent' => rv.agent,
                         'model' => rv.agents.model(rv.agent, phase), 'status' => status,
                         'cost_usd' => Usage.cost(result, rv.agent),
                         'tokens' => result&.tokens || Usage::TOKEN_KEYS.to_h { |k| [k, 0] }
                       })
    end

    # paths relative to the workspace; commits only these paths, other staged changes stay staged
    def commit(paths, msg)
      paths = paths.select { |p| File.exist?(File.join(@workspace_dir, p)) }
      return true if paths.empty?

      return true if clean?(paths)
      return true if git('add', '--', *paths).first && git('commit', '-q', '-m', msg, '--', *paths).first
      return false unless clean?(paths)

      say "#{paths.join(', ')} committed by another session"
      true
    end

    def clean?(paths)
      ok, out = git('status', '--porcelain', '--', *paths)
      ok && out.strip.empty?
    end

    # stdout_only: output without stderr, so a git warning never reads as a path
    def git(*args, stdout_only: false)
      tries = 0
      loop do
        out, err, st = Open3.capture3('git', *args, chdir: @workspace_dir)
        return [true, stdout_only ? out : out + err] if st.success?

        out += err

        if out.include?('index.lock') && tries < GIT_RETRIES
          tries += 1
          say "git #{args.first}: index.lock held, retry #{tries}/#{GIT_RETRIES}"
          @sleeper.call(GIT_RETRY_WAIT)
          next
        end
        say "ERROR: git #{args.first} failed: #{out.strip}"
        return [false, out]
      end
    end

    def warn_api_key
      say API_KEY_WARNING unless ENV['ANTHROPIC_API_KEY'].to_s.empty?
    end

    def warn_codex_key(rv)
      return if (@forced || rv.agents.mode) == 'claude'

      say CODEX_KEY_WARNING if %w[OPENAI_API_KEY CODEX_API_KEY].any? { |k| !ENV[k].to_s.empty? }
    end

    def fail_review(project, topic, msg)
      say "FAILED: #{msg}"
      notify("FAIL-#{project}-#{topic}", msg)
      false
    end

    def notify(window, msg)
      return if ENV['TMUX'].to_s.empty?

      system('tmux', 'new-window', '-d', '-n', window, "echo #{Shellwords.escape(msg)}; read")
    end

    def say(msg)
      @out.puts "[#{@clock.call.strftime('%H:%M:%S')}] #{msg}"
    end
  end
end
