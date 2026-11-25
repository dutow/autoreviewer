module ReviewRun
  Context = Struct.new(:project, :topic, :version, :outdir, :prev_dir, :index, :total, :replay, :note, keyword_init: true)

  module Prompt
    FRONTMATTER = /\A---[ \t]*\n.*?^---[ \t]*\n/m
    REPLAY_NOTE = 'Replay of a past review: if discussion.txt already exists in the output directory, ' \
                  'it is the discussion as of the original review; use it as it is and do not fetch or regenerate it.'

    DISCOVERY_NOTE = 'Discovery pass: run only the overview, design review and code review phases of the instructions below, ' \
                     'then stop. Do not validate findings, do not cross-reference the discussion, and do not write a summary, ' \
                     'findings.json or a reply draft. Do not read or write anything in the version directory outside the ' \
                     'output directory above; another reviewer works there independently.'

    def self.primary_note(dir)
      "An independent discovery pass by another reviewer wrote `#{dir}/01-design-review.md` and `#{dir}/02-code-review.md`. " \
        "Do not read anything under `#{dir}/` until your own code review is written. Then, before validation: add each code " \
        'finding from that pass that is not already in your code review as a candidate, marked `Found by: second reviewer`, ' \
        "and validate all candidates the same way. Weigh its design concerns in your summary. Do not modify files under `#{dir}/`."
    end

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
      h = <<~H
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
      h = "#{h}#{REPLAY_NOTE}\n" if ctx.replay
      h = "#{h}\n#{ctx.note}\n" if ctx.note
      h
    end
  end
end
