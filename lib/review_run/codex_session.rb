require 'open3'
require 'fileutils'

require_relative 'session'
require_relative 'codex_stream'

module ReviewRun
  # one `codex exec --json` run: prompt on stdin, raw stream appended to log, formatted to out
  class CodexSession
    def initialize(codex_bin:, workspace_dir:, out:)
      @codex_bin = codex_bin
      @workspace_dir = workspace_dir
      @out = out
    end

    # -> [CodexResult or nil, Process::Status, nil]; raises SystemCallError when codex cannot start
    def run(prompt, model:, effort:, log:)
      cmd = [@codex_bin, 'exec', '--json', '--dangerously-bypass-approvals-and-sandbox',
             '-C', @workspace_dir, '-m', model]
      cmd += ['-c', "model_reasoning_effort=#{effort}"] if effort
      cmd << '-'
      FileUtils.mkdir_p(File.dirname(log))
      events = []
      status = nil
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      File.open(log, 'a') do |lf|
        Open3.popen2e(Session::CHILD_ENV, *cmd, chdir: @workspace_dir, unsetenv_others: false) do |stdin, io, wait|
          begin
            stdin.write(prompt)
          rescue Errno::EPIPE
            nil
          end
          stdin.close
          io.set_encoding(Encoding::UTF_8)
          io.each_line do |line|
            lf.write(line)
            lf.flush
            ev = show(line)
            events << ev if ev
          end
          status = wait.value
        end
      end
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      [to_result(events, model, ms), status, nil]
    end

    def version
      out, = Open3.capture2e(Session::CHILD_ENV, @codex_bin, '--version', unsetenv_others: false)
      out.split.last || 'unknown'
    rescue SystemCallError
      'unknown'
    end

    private

    def show(line)
      ev = Stream.parse_line(line)
      text = ev ? CodexStream.format_event(ev) : line.chomp
      @out.puts(text) unless text.nil? || text.strip.empty?
      ev
    rescue StandardError
      @out.puts(line.chomp)
      ev
    end

    def to_result(events, model, duration_ms)
      return nil if events.empty?

      CodexResult.new(events, model: model, duration_ms: duration_ms)
    rescue StandardError
      nil
    end
  end
end
