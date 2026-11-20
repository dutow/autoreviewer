require 'open3'
require 'fileutils'

require_relative 'stream'

module ReviewRun
  # one `claude -p` run: prompt on stdin, raw stream appended to log, formatted to out
  class Session
    # REVIEW_RUN: marker for workspace hooks; done file is review-run's, not the session's
    CHILD_ENV = { 'REVIEW_DONE_FILE' => nil, 'REVIEW_RUN' => '1', 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS' => '1' }.freeze

    def initialize(claude_bin:, workspace_dir:, out:)
      @claude_bin = claude_bin
      @workspace_dir = workspace_dir
      @out = out
    end

    # -> [Result or nil, Process::Status, last rejected RateLimit or nil]; raises SystemCallError when claude cannot start
    def run(prompt, model:, effort:, log:)
      cmd = [@claude_bin, '-p']
      cmd += ['--model', model] if model
      cmd += ['--effort', effort] if effort
      cmd += %w[--dangerously-skip-permissions --disallowedTools AskUserQuestion
                --output-format stream-json --verbose]
      FileUtils.mkdir_p(File.dirname(log))
      result_ev = nil
      rate_limit = nil
      status = nil
      File.open(log, 'a') do |lf|
        Open3.popen2e(CHILD_ENV, *cmd, chdir: @workspace_dir, unsetenv_others: false) do |stdin, io, wait|
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
            result_ev = ev if ev && ev['type'] == 'result'
            rl = ev && RateLimit.from_event(ev)
            rate_limit = rl if rl&.rejected?
          end
          status = wait.value
        end
      end
      [to_result(result_ev), status, rate_limit]
    end

    def version
      out, = Open3.capture2e(CHILD_ENV, @claude_bin, '--version', unsetenv_others: false)
      out.split.first || 'unknown'
    rescue SystemCallError
      'unknown'
    end

    private

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
  end
end
