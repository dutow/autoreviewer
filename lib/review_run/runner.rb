require 'open3'
require 'json'
require 'yaml'
require 'fileutils'
require 'shellwords'
require 'time'

require_relative 'manifest'
require_relative 'prompt'
require_relative 'stream'
require_relative 'usage'
require_relative 'findings_dir'

module ReviewRun
  class RunError < StandardError; end

  class Runner
    GIT_RETRIES = 5
    GIT_RETRY_WAIT = 2
    CHILD_ENV = { 'REVIEW_DONE_FILE' => nil }.freeze
    API_KEY_WARNING = 'WARNING: ANTHROPIC_API_KEY is set; claude -p will bill the API key'.freeze

    Review = Struct.new(:project, :topic, :version, :route, :yaml, :manifest, :phases,
                        :outdir, :prev_dir, keyword_init: true)

    def initialize(base_dir:, workspace_dir:, state_dir:, claude_bin: 'claude', out: $stdout,
                   sleeper: ->(s) { sleep s }, clock: -> { Time.now })
      @base_dir = base_dir
      @workspace_dir = workspace_dir
      @state_dir = state_dir
      @claude_bin = claude_bin
      @out = out
      @sleeper = sleeper
      @clock = clock
    end

    def run_topic(project:, topic:, route: nil)
      warn_api_key
      rv = load_review(project, topic, route)
      rel = FindingsDir.prepare(base_dir: @base_dir, project_dir: project_dir(project), topic: topic)
      raise RunError, 'could not prepare findings dir' unless rel

      rv.outdir = File.join(project, rel)
      outdir_abs = File.join(@workspace_dir, rv.outdir)
      usage = Usage.new(path: File.join(outdir_abs, 'usage.json'), route: rv.route, claude_version: claude_version)
      say "=== review #{project}/#{topic} v#{rv.version}, route #{rv.route}, #{rv.phases.size} phases"

      rv.phases.each_with_index do |phase, idx|
        if (why = skip_reason(phase, outdir_abs))
          say "skip #{phase.name}: #{why}"
          next
        end
        return false unless run_phase(rv, phase, idx, usage)
      end
      finish(rv, usage)
    rescue StandardError => e
      msg = e.is_a?(RunError) || e.is_a?(ManifestError) ? e.message : "#{e.class}: #{e.message} (#{e.backtrace&.first})"
      fail_review(project, topic, msg)
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
                 outdir: File.join(project, 'findings', topic, "v#{version}"),
                 prev_dir: prev && File.join(project, prev))
    end

    def context(rv, idx)
      Context.new(project: rv.project, topic: rv.topic, version: "v#{rv.version}", outdir: rv.outdir,
                  prev_dir: rv.prev_dir, index: idx + 1, total: rv.phases.size)
    end

    def skip_reason(phase, outdir_abs)
      return "#{phase.output} exists" if phase.output && File.exist?(File.join(outdir_abs, phase.output))

      'skip_if matched' if phase.skip?(outdir_abs)
    end

    def run_phase(rv, phase, idx, usage)
      prompt = Prompt.render(manifest: rv.manifest, phase: phase, ctx: context(rv, idx))
      log = File.join(@state_dir, 'logs', "#{rv.project}-#{rv.topic}", format('%02d-%s.jsonl', idx + 1, phase.name))
      say "=== phase #{phase.name} (#{idx + 1} of #{rv.phases.size}), model #{phase.model}" \
          "#{", effort #{phase.effort}" if phase.effort}"
      started = @clock.call
      result, status = run_claude(prompt, model: phase.model, effort: phase.effort, log: log)
      reason = phase_failure(rv, phase, result, status)
      log_usage(project: rv.project, topic: rv.topic, version: rv.version, route: rv.route,
                phase: phase.name, model: phase.model, status: reason ? 'failed' : 'ok', result: result)
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

      commit([file], "review(#{rv.topic}): #{phase.name} output (runner)") ? nil : "could not commit #{file}"
    end

    def exit_desc(status)
      return 'claude did not start' unless status

      status.exited? ? "exit #{status.exitstatus}" : status.to_s
    end

    def run_claude(prompt, model:, effort:, log:)
      cmd = [@claude_bin, '-p']
      cmd += ['--model', model] if model
      cmd += ['--effort', effort] if effort
      cmd += %w[--dangerously-skip-permissions --disallowedTools AskUserQuestion
                --output-format stream-json --verbose]
      FileUtils.mkdir_p(File.dirname(log))
      result_ev = nil
      status = nil
      File.open(log, 'a') do |lf|
        Open3.popen2e(CHILD_ENV, *cmd, chdir: @workspace_dir, unsetenv_others: false) do |stdin, io, wait|
          begin
            stdin.write(prompt)
          rescue Errno::EPIPE
            nil
          end
          stdin.close
          io.each_line do |line|
            lf.write(line)
            lf.flush
            ev = show(line)
            result_ev = ev if ev && ev['type'] == 'result'
          end
          status = wait.value
        end
      end
      [to_result(result_ev), status]
    rescue SystemCallError => e
      say "ERROR: could not run #{@claude_bin}: #{e.message}"
      [nil, nil]
    end

    def show(line)
      ev = Stream.parse_line(line)
      text = ev ? Stream.format_event(ev) : line.chomp
      @out.puts(text) unless text.nil? || text.strip.empty?
      ev
    rescue StandardError
      @out.puts(line.chomp)
      ev
    end

    def to_result(event)
      event && Result.from_event(event)
    rescue StandardError
      nil
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

    def log_usage(project:, topic:, version:, route:, phase:, model:, status:, result:)
      Usage.append_log(File.join(@state_dir, 'usage.log'), {
                         'time' => @clock.call.iso8601, 'project' => project, 'topic' => topic,
                         'version' => version, 'route' => route, 'phase' => phase, 'model' => model,
                         'status' => status, 'cost_usd' => result&.cost_usd || 0.0,
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

    def claude_version
      out, = Open3.capture2e(CHILD_ENV, @claude_bin, '--version', unsetenv_others: false)
      out.split.first || 'unknown'
    rescue SystemCallError
      'unknown'
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
