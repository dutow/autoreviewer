module ReviewRun
  Context = Struct.new(:project, :topic, :version, :outdir, :prev_dir, :index, :total, keyword_init: true)

  module Prompt
    FRONTMATTER = /\A---[ \t]*\n.*?^---[ \t]*\n/m

    def self.render(manifest:, phase:, ctx:)
      parts = []
      parts << body(File.join(manifest.dir, 'shared.md')) if phase.shared
      parts << body(manifest.prompt_path(phase))
      text = parts.join("\n")
      text = text.gsub('$ARGUMENTS') { ctx.topic }.gsub('$OUTDIR') { ctx.outdir }.gsub('$PROJECT') { ctx.project }
      "#{header(phase, ctx)}\n#{text}"
    end

    def self.render_command(path:, args:)
      body(path).gsub('$ARGUMENTS') { args }
    end

    def self.body(path)
      File.read(path).sub(FRONTMATTER, '')
    end

    def self.header(phase, ctx)
      <<~H
        # Automated review phase

        Project: #{ctx.project}
        Topic: #{ctx.topic}
        Version: #{ctx.version}
        Phase: #{phase.name} (#{ctx.index} of #{ctx.total})
        Output directory: #{ctx.outdir}
        Review worktree: #{ctx.project}/review/#{ctx.topic}
        Previous reviewed version: #{ctx.prev_dir || 'none'}

        #{ctx.total == 1 ? 'Run' : 'Run only this phase,'} without stopping for user input.
        Do not start background agents or background tasks; wait for every subagent to finish before you end.
        All paths are relative to the workspace root (the current directory).
      H
    end
  end
end
