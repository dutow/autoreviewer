require 'json'
require 'fileutils'
require 'time'

module ReviewRun
  # usage-limit pause flag shared by runners and the queue: {"until": iso8601, "by": window}
  class Pause
    def initialize(path)
      @path = path
    end

    def set(until_time, by:)
      FileUtils.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.generate('until' => until_time.iso8601, 'by' => by) + "\n")
      File.rename(tmp, @path)
    end

    # nil when missing or unreadable
    def until_time
      Time.iso8601(JSON.parse(File.read(@path)).fetch('until'))
    rescue StandardError
      nil
    end

    # removes the file once past, or when corrupt
    def active?(now)
      return false unless File.exist?(@path)

      t = until_time
      return true if t && t > now

      clear
      false
    end

    def clear
      FileUtils.rm_f(@path)
    end
  end
end
