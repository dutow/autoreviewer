require 'json'
require 'fileutils'
require 'open3'
require 'pathname'
require 'time'

module ReviewReplay
  class ReplayError < StandardError; end

  Run = Struct.new(:project, :topic, :version, :route, :dir, :ws, :state, :reference, :head,
                   :live_master, :worktree, keyword_init: true)

  # throwaway copy of the live workspace for re-running one reviewed version
  class Workspace
    LINKED = %w[master branches builds].freeze
    NAME = /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/

    def initialize(workspace_dir:, replay_root:, out: $stdout)
      @live = File.realpath(workspace_dir)
      @root = File.expand_path(replay_root)
      @out = out
    end

    def prepare(project:, topic:, version:, route:)
      run = check(project, topic, parse_version(version), route)
      begin
        claim_dir(run)
        clone(run)
        drop_versions(run)
        link_live_dirs(run)
        add_worktree(run)
        seed(run)
        write_meta(run)
      rescue StandardError => e
        cleanup(run)
        FileUtils.rm_rf(run.dir) if run.dir
        raise e if e.is_a?(ReplayError)

        raise ReplayError, "prepare failed: #{e.message}"
      end
      run
    end

    def inputs_changed?(run)
      review = live_review(run.project, run.topic)
      meta = File.join(review, 'metadata.json')
      return true unless File.file?(meta)

      ok, head = git(review, 'rev-parse', 'HEAD')
      return true unless ok && head.strip == run.head

      JSON.parse(File.read(meta))['version'].to_i != run.version
    rescue JSON::ParserError, SystemCallError
      true
    end

    def cleanup(run)
      return unless run.live_master && run.worktree

      ok, out = git(run.live_master, 'worktree', 'remove', '--force', run.worktree)
      say "WARNING: could not remove worktree #{run.worktree}: #{out.strip}" if !ok && File.exist?(run.worktree)
      git(run.live_master, 'worktree', 'prune')
    rescue StandardError => e
      say "WARNING: worktree cleanup: #{e.message}"
    end

    private

    def parse_version(version)
      Integer(version.to_s.delete_prefix('v'), 10)
    rescue ArgumentError
      raise ReplayError, "bad version: #{version}"
    end

    def check(project, topic, version, route)
      [project, topic, route].each { |s| raise ReplayError, "bad name: #{s.inspect}" unless s.to_s.match?(NAME) }
      yaml = File.join(@live, project, 'project.yaml')
      raise ReplayError, "project.yaml not found: #{yaml}" unless File.file?(yaml)

      rel = File.join(project, 'findings', topic, "v#{version}")
      reference = File.join(@live, rel)
      raise ReplayError, "no finished review at #{rel}" unless File.file?(File.join(reference, '05-summary.md'))

      review = live_review(project, topic)
      at = ingested_version(project, topic, review)
      unless at == version
        raise ReplayError, "#{project}/review/#{topic} is at v#{at}, not v#{version}; " \
                           "replay needs the live ingest of v#{version}"
      end

      master = File.join(@live, project, 'master')
      raise ReplayError, "master checkout not found: #{master}" unless File.directory?(master)

      Run.new(project: project, topic: topic, version: version, route: route, reference: reference,
              head: git!(review, 'rev-parse', 'HEAD').strip, live_master: master)
    end

    def ingested_version(project, topic, review)
      meta = File.join(review, 'metadata.json')
      raise ReplayError, "#{project}/review/#{topic} not ingested" unless File.file?(meta)

      JSON.parse(File.read(meta))['version'].to_i
    rescue JSON::ParserError => e
      raise ReplayError, "#{meta}: #{e.message}"
    end

    # v<N>-<route>-<n>, n one above the highest taken; mkdir claims it
    def claim_dir(run)
      base = File.join(@root, run.project, run.topic)
      FileUtils.mkdir_p(base)
      prefix = "v#{run.version}-#{run.route}-"
      used = Dir.children(base).filter_map { |c| c.delete_prefix(prefix)[/\A\d+\z/]&.to_i if c.start_with?(prefix) }
      n = used.max || 0
      begin
        n += 1
        Dir.mkdir(File.join(base, "#{prefix}#{n}"))
      rescue Errno::EEXIST
        retry
      end
      run.dir = File.realpath(File.join(base, "#{prefix}#{n}"))
      run.ws = File.join(run.dir, 'ws')
      run.state = File.join(run.dir, 'state')
    end

    def clone(run)
      git!(run.dir, 'clone', '-q', '--shared', @live, run.ws)
      git!(run.ws, 'remote', 'remove', 'origin')
      { 'user.name' => 'replay', 'user.email' => 'replay@localhost' }.each do |key, fallback|
        ok, val = git(@live, 'config', '--get', key)
        git!(run.ws, 'config', key, ok && !val.strip.empty? ? val.strip : fallback)
      end
      git!(run.ws, 'config', 'commit.gpgsign', 'false')
    end

    def drop_versions(run)
      dir = File.join(run.ws, run.project, 'findings', run.topic)
      return unless File.directory?(dir)

      drop = Dir.children(dir).select { |c| (m = c[/\Av(\d+)\z/, 1]) && m.to_i >= run.version }.sort
      return if drop.empty?

      git!(run.ws, 'rm', '-r', '-q', '--', *drop.map { |c| File.join(run.project, 'findings', run.topic, c) })
      git!(run.ws, 'commit', '-q', '-m', "replay: drop #{run.topic} v#{run.version}+")
    end

    def link_live_dirs(run)
      Dir.glob(File.join(@live, '*', 'project.yaml')).each do |yaml|
        project = File.basename(File.dirname(yaml))
        LINKED.each do |d|
          src = File.join(@live, project, d)
          dst = File.join(run.ws, project, d)
          next unless File.exist?(src)
          next if File.exist?(dst) || File.symlink?(dst)

          FileUtils.mkdir_p(File.dirname(dst))
          File.symlink(Pathname.new(src).relative_path_from(Pathname.new(File.dirname(dst))).to_s, dst)
        end
      end
    end

    def add_worktree(run)
      run.worktree = File.join(run.ws, run.project, 'review', run.topic)
      git!(run.live_master, 'worktree', 'add', '-q', '--detach', run.worktree, run.head)
      review = live_review(run.project, run.topic)
      git!(review, 'ls-files', '--others', '-z').split("\0").each do |rel|
        src = File.join(review, rel)
        next unless File.file?(src)

        dst = File.join(run.worktree, rel)
        FileUtils.mkdir_p(File.dirname(dst))
        FileUtils.cp(src, dst, preserve: true)
      end
    end

    def seed(run)
      vdir = File.join(run.ws, run.project, 'findings', run.topic, "v#{run.version}")
      FileUtils.mkdir_p(vdir)
      disc = File.join(run.reference, 'discussion.txt')
      FileUtils.cp(disc, vdir) if File.file?(disc)
    end

    def write_meta(run)
      FileUtils.mkdir_p(run.state)
      File.symlink(File.join('ws', run.project, 'findings', run.topic, "v#{run.version}"), File.join(run.dir, 'findings'))
      meta = { 'project' => run.project, 'topic' => run.topic, 'version' => run.version, 'route' => run.route,
               'reference' => run.reference, 'head' => run.head, 'created_at' => Time.now.utc.iso8601 }
      File.write(File.join(run.dir, 'replay.json'), "#{JSON.pretty_generate(meta)}\n")
    end

    def live_review(project, topic)
      File.join(@live, project, 'review', topic)
    end

    def git(dir, *args)
      out, err, st = Open3.capture3('git', *args, chdir: dir)
      [st.success?, st.success? ? out : "#{out}#{err}"]
    end

    def git!(dir, *args)
      ok, out = git(dir, *args)
      raise ReplayError, "git #{args.first(2).join(' ')} failed: #{out.strip}" unless ok

      out
    end

    def say(msg)
      @out.puts msg
    end
  end
end
