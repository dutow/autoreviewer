require 'fileutils'
require 'json'
require 'open3'
require 'yaml'

# live workspace for replay tests: project p (topic t1 ingested at v2, reviewed v1-v3), project q
module ReplayFixture
  module_function

  def git(dir, *args)
    out, st = Open3.capture2e('git', *args, chdir: dir)
    raise "git #{args.join(' ')} in #{dir}: #{out}" unless st.success?

    out
  end

  def init_repo(dir)
    FileUtils.mkdir_p(dir)
    git(dir, 'init', '-q', '-b', 'main')
    git(dir, 'config', 'user.email', 'test@example.com')
    git(dir, 'config', 'user.name', 'test')
    git(dir, 'config', 'commit.gpgsign', 'false')
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def live_workspace(root)
    ws = File.join(root, 'ws')
    init_repo(ws)
    write(File.join(ws, '.gitignore'), "*/master\n*/review\n*/builds\n*/branches\n*/current-reviews\n")
    write(File.join(ws, 'p', 'project.yaml'), YAML.dump('name' => 'p', 'review' => { 'phases' => 'p', 'route' => 'single' }))
    write(File.join(ws, 'q', 'project.yaml'), YAML.dump('name' => 'q'))
    phases = File.join(ws, '.claude', 'review-phases', 'p')
    write(File.join(phases, 'review.md'), "Review $ARGUMENTS into $OUTDIR\n")
    write(File.join(phases, '01-a.md'), "Do a for $ARGUMENTS into $OUTDIR\n")
    write(File.join(phases, '02-b.md'), "Do b for $ARGUMENTS into $OUTDIR\n")
    write(File.join(phases, 'phases.yaml'), YAML.dump(
      'default_model' => 'opus',
      'routes' => {
        'single' => [{ 'name' => 'review', 'prompt' => 'review.md', 'output' => '05-summary.md' }],
        'full' => [{ 'name' => 'a', 'prompt' => '01-a.md', 'output' => 'a.md' },
                   { 'name' => 'b', 'prompt' => '02-b.md', 'output' => '05-summary.md' }]
      }
    ))
    findings = File.join(ws, 'p', 'findings', 't1')
    %w[v1 v2 v3].each { |v| write(File.join(findings, v, '05-summary.md'), "summary #{v}\n") }
    write(File.join(findings, 'v2', 'discussion.txt'), "thread as of v2\n")
    git(ws, 'add', '-A')
    git(ws, 'commit', '-q', '-m', 'init')

    master = File.join(ws, 'p', 'master')
    init_repo(master)
    write(File.join(master, 'a.c'), "int a;\n")
    git(master, 'add', '-A')
    git(master, 'commit', '-q', '-m', 'base')
    review = File.join(ws, 'p', 'review', 't1')
    git(master, 'worktree', 'add', '-q', '--detach', review, 'HEAD')
    write(File.join(review, 'metadata.json'), JSON.generate('version' => 2))
    write(File.join(review, '.hackorum', '0001.patch'), "patch 1\n")

    write(File.join(ws, 'p', 'builds', 't1', 'debug', 'status.yaml'), "build: ok\n")
    FileUtils.mkdir_p(File.join(ws, 'q', 'builds', 'master'))
    ws
  end
end
