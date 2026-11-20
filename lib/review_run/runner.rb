require 'open3'
require 'json'
require 'yaml'
require 'shellwords'
require 'time'

require_relative 'manifest'
require_relative 'prompt'
require_relative 'usage'
require_relative 'findings_dir'
require_relative 'session'
require_relative 'pause'

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

    Review = Struct.new(:project, :topic, :version, :route, :yaml, :manifest, :phases,
                        :outdir, :prev_dir, :window, keyword_init: true)
    CommitPhase = Struct.new(:name, :model, :effort)

    def initialize(base_dir:, workspace_dir:, state_dir:, claude_bin: 'claude', out: $stdout,
                   sleeper: ->(s) { sleep s }, clock: -> { Time.now })
      @base_dir = base_dir
      @workspace_dir = workspace_dir
      @state_dir = state_dir
      @claude_bin = claude_bin
      @out = out
      @sleeper = sleeper
      @clock = clock
      @session = Session.new(claude_bin: claude_bin, workspace_dir: workspace_dir, out: out)
      @pause = Pause.new(File.join(state_dir, 'paused'))
    end

    def run_topic(project:, topic:, route: nil)
      warn_api_key
      rv = load_review(project, topic, route)
      rel = FindingsDir.prepare(base_dir: @base_dir, project_dir: project_dir(project), topic: topic)
      raise RunError, 'could not prepare findings dir' unless rel

      rv.outdir = File.join(project, rel)
      outdir_abs = File.join(@workspace_dir, rv.outdir)
      usage = Usage.new(path: File.join(outdir_abs, 'usage.json'), route: rv.route, claude_version: @session.version)
      say "=== review #{project}/#{topic} v#{rv.version}, route #{rv.route}, #{rv.phases.size} phases"

      rv.phases.each_with_index do |phase, idx|
        if (why = skip_reason(phase, outdir_abs, usage))
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
      rv = Review.new(project: project, topic: range, version: nil, route: 'commits', window: window)
      phase = CommitPhase.new('commits', 'opus', nil)
      prompt = Prompt.render_command(path: commit_command_path(project), args: range)
      log = File.join(@state_dir, 'logs', window, 'commits.jsonl')
      say "=== commit review #{project} #{range}, model opus"
      _started, result, status, reason = run_past_limit(rv, phase, prompt, log)
      reason ||= commits_failure(result, status)
      log_usage(rv, phase, reason ? 'failed' : 'ok', result)
      return fail_review(project, window.delete_prefix("#{project}-"), reason) if reason

      say "=== commit review #{project} #{range} done"
      true
    rescue StandardError => e
      msg = e.is_a?(RunError) ? e.message : "#{e.class}: #{e.message} (#{e.backtrace&.first})"
      fail_review(project, 'commits', msg)
    end

    def render(project:, topic:, phase:, route: nil)
      rv = load_review(project, topic, route)
      idx = rv.phases.index { |p| p.name == phase }
      raise RunError, "phase #{phase} not in route #{rv.route}" unless idx

      Prompt.render(manifest: rv.manifest, phase: rv.phases[idx], ctx: context(rv, idx))
    end

    private

    def project_dir(project)
      File.join(@workspace_dir, project)
    end

    def load_review(project, topic, route)
      yaml = File.join(project_dir(project), 'project.yaml')
      raise RunError, "project.yaml not found: #{yaml}" unless File.exist?(yaml)

      config = YAML.safe_load_file(yaml) || {}
      family = config.dig('review', 'phases')
      raise RunError, "#{yaml}: review.phases not set" if family.to_s.empty?

      route ||= config.dig('review', 'route') || 'full'
      mpath = File.join(@workspace_dir, '.claude', 'review-phases', family, 'phases.yaml')
      raise RunError, "phase manifest not found: #{mpath}" unless File.exist?(mpath)

      manifest = Manifest.load(mpath)
      meta = File.join(project_dir(project), 'review', topic, 'metadata.json')
      raise RunError, "#{meta} not found" unless File.exist?(meta)

      version = JSON.parse(File.read(meta))['version']
      raise RunError, "version missing in #{meta}" if version.nil?

      prev = FindingsDir.previous_version(project_dir: project_dir(project), topic: topic, version: version)
      Review.new(project: project, topic: topic, version: version, route: route, yaml: yaml,
                 manifest: manifest, phases: manifest.route(route),
                 outdir: File.join(project, 'findings', topic, "v#{version}"), window: "#{project}-#{topic}",
                 prev_dir: prev && File.join(project, prev))
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

    def commits_failure(result, status)
      return "no result event (#{exit_desc(status)})" unless result
      return "claude error (#{result.subtype}): #{result.text[0, 300]}" if result.is_error
      return "claude #{exit_desc(status)}" unless status&.success?

      nil
    end

    def context(rv, idx)
      Context.new(project: rv.project, topic: rv.topic, version: "v#{rv.version}", outdir: rv.outdir,
                  prev_dir: rv.prev_dir, index: idx + 1, total: rv.phases.size)
    end

    # resume: output present and last run of the phase did not fail
    def skip_reason(phase, outdir_abs, usage)
      if phase.output && File.exist?(File.join(outdir_abs, phase.output)) &&
         usage.last_status(phase.name) != 'failed'
        return "#{phase.output} exists"
      end

      'skip_if matched' if phase.skip?(outdir_abs)
    end

    def commit_output(rv, phase)
      return true unless phase.output

      commit([File.join(rv.outdir, phase.output)], "review(#{rv.topic}): #{phase.name} output (runner)")
    end

    def run_phase(rv, phase, idx, usage)
      prompt = Prompt.render(manifest: rv.manifest, phase: phase, ctx: context(rv, idx))
      log = File.join(@state_dir, 'logs', "#{rv.project}-#{rv.topic}", format('%02d-%s.jsonl', idx + 1, phase.name))
      say "=== phase #{phase.name} (#{idx + 1} of #{rv.phases.size}), model #{phase.model}" \
          "#{", effort #{phase.effort}" if phase.effort}"
      started, result, status, reason = run_past_limit(rv, phase, prompt, log)
      reason ||= phase_failure(rv, phase, result, status)
      log_usage(rv, phase, reason ? 'failed' : 'ok', result)
      if reason
        usage.fail(phase: phase.name, reason: reason, result: result, started_at: started)
        save_usage(rv, usage)
        fail_review(rv.project, rv.topic, "phase #{phase.name}: #{reason}")
        return false
      end
      usage.add(phase: phase.name, model: phase.model, result: result, started_at: started)
      usage.write
      true
    end

    def phase_failure(rv, phase, result, status)
      return "no result event (#{exit_desc(status)})" unless result
      return "claude error (#{result.subtype}): #{result.text[0, 300]}" if result.is_error
      return "claude #{exit_desc(status)}" unless status&.success?
      return nil unless phase.output

      file = File.join(rv.outdir, phase.output)
      return "output #{file} missing" unless File.exist?(File.join(@workspace_dir, file))

      commit_output(rv, phase) ? nil : "could not commit #{file}"
    end

    def exit_desc(status)
      return 'claude did not start' unless status

      status.exited? ? "exit #{status.exitstatus}" : status.to_s
    end

    # usage limit: pause, wait for the reset, re-run; reason set once retries run out
    def run_past_limit(rv, phase, prompt, log)
      hits = 0
      loop do
        started = @clock.call
        result, status = run_claude(prompt, phase, log)
        unless result&.limit_hit?
          @pause.clear if hits.positive? && @pause.by == rv.window
          return [started, result, status, nil]
        end

        hits += 1
        until_t = limit_until(result)
        @pause.set(until_t, by: rv.window)
        return [started, result, status, 'usage limit, retries exhausted'] if hits > LIMIT_RETRIES

        log_usage(rv, phase, 'limit', result)
        say "usage limit in phase #{phase.name}, paused until #{until_t.strftime('%Y-%m-%d %H:%M:%S')} " \
            "(retry #{hits}/#{LIMIT_RETRIES})"
        @sleeper.call([(until_t - @clock.call).ceil, 0].max)
      end
    end

    def limit_until(result)
      now = @clock.call
      reset = begin
        result.limit_reset(now)
      rescue StandardError
        now + LIMIT_FALLBACK_WAIT
      end
      [reset + LIMIT_GRACE, now + LIMIT_MIN_WAIT].max
    end

    def run_claude(prompt, phase, log)
      @session.run(prompt, model: phase.model, effort: phase.effort, log: log)
    rescue SystemCallError => e
      say "ERROR: could not run #{@claude_bin}: #{e.message}"
      [nil, nil]
    end

    def finish(rv, usage)
      run_findings_metadata(rv)
      return fail_review(rv.project, rv.topic, 'could not commit usage.json') unless save_usage(rv, usage)

      say "=== review #{rv.project}/#{rv.topic} done"
      true
    end

    def save_usage(rv, usage)
      usage.write
      commit(%w[usage.json metadata.json].map { |f| File.join(rv.outdir, f) }, "review(#{rv.topic}): add usage")
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
                         'version' => rv.version, 'route' => rv.route, 'phase' => phase.name,
                         'model' => phase.model, 'status' => status, 'cost_usd' => result&.cost_usd || 0.0,
                         'tokens' => result&.tokens || Usage::TOKEN_KEYS.to_h { |k| [k, 0] }
                       })
    end

    # paths relative to the workspace; commits only these paths, other staged changes stay staged
    def commit(paths, msg)
      paths = paths.select { |p| File.exist?(File.join(@workspace_dir, p)) }
      return true if paths.empty?

      ok, out = git('status', '--porcelain', '--', *paths)
      return false unless ok
      return true if out.strip.empty?

      git('add', '--', *paths).first && git('commit', '-q', '-m', msg, '--', *paths).first
    end

    def git(*args)
      tries = 0
      loop do
        out, st = Open3.capture2e('git', *args, chdir: @workspace_dir)
        return [true, out] if st.success?

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
