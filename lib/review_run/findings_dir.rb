require 'fileutils'
require 'json'

module ReviewRun
  module FindingsDir
    def self.log(msg)
      puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
    end

    def self.prepare(base_dir:, project_dir:, topic:)
      meta_file = File.join(project_dir, 'review', topic, 'metadata.json')
      unless File.exist?(meta_file)
        log "WARNING: #{meta_file} not found; leaving findings dir to Claude"
        return nil
      end
      version = JSON.parse(File.read(meta_file))['version']
      if version.nil?
        log 'WARNING: version missing in metadata; leaving findings dir to Claude'
        return nil
      end

      rel = File.join('findings', topic, "v#{version}")
      FileUtils.mkdir_p(File.join(project_dir, rel))

      current = File.join(project_dir, 'current-reviews')
      FileUtils.mkdir_p(current)
      link = File.join(current, topic)
      FileUtils.rm_f(link) if File.symlink?(link) || File.exist?(link)
      File.symlink(File.join('..', rel), link)
      log "Findings dir ready: #{rel}"

      meta_cmd = [File.join(base_dir, 'bin', 'findings-metadata'),
                  '--project', File.join(project_dir, 'project.yaml'), topic]
      log 'WARNING: findings-metadata failed (continuing)' unless system(*meta_cmd)

      rel
    rescue => e
      log "WARNING: could not prepare findings dir: #{e.message}"
      nil
    end

    def self.previous_version(project_dir:, topic:, version:)
      root = File.join(project_dir, 'findings', topic)
      best = Dir.glob(File.join(root, 'v*')).filter_map do |d|
        m = File.basename(d).match(/\Av(\d+)\z/) or next
        n = m[1].to_i
        n if n < version.to_i && File.exist?(File.join(d, '05-summary.md'))
      end.max
      best && File.join('findings', topic, "v#{best}")
    end
  end
end
