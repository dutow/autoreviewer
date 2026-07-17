# autoreviewer

Queues patch and PR reviews and runs them as subscription-based Claude Code sessions, one tmux window per topic.
Findings are written as versioned files into your own private workspace repo, not into this repo.
A small web UI serves those findings for browsing and search.

## Two-repo model

This repo (`autoreviewer`) is code:
the queue orchestrator, compose files, Dockerfiles, the webapp.
It is public-shaped and holds nothing about what you review or found.

Your data and config - which projects you review, build hooks, review prompts, and every finding ever written - live in a separate git repo, checked out at `workspace/` (gitignored here, private by default).
See [docs/workspace.md](docs/workspace.md) for what goes in it.

## Requirements

- Docker or Podman
- go-task (`task`)
- git

Nothing else needs to be installed on the host - everything else runs inside the container image built by `task build`.

## Quickstart

`task init-workspace` seeds `workspace/` from the reference example (postgres, pg_tde, psp reference projects) and git-inits it - use and edit it to start fresh.
If you already have your own workspace repo, clone it instead.

```
git clone https://github.com/dutow/autoreviewer.git && cd autoreviewer
task init-workspace          # or: git clone <your workspace repo> workspace
task setup                   # creates .env; defaults are fine for localhost
task build
task login                   # claude auth, one time
task up
task enqueue -- pg_tde 123   # review PR 123
task attach                  # watch it work; Ctrl-b d to detach
# findings: http://localhost:8080
```

## What happens on enqueue

`task enqueue` appends a line to the queue file.
The orchestrator picks it up, runs the project's ingestion hook (fetch the patch/PR and normalize its metadata), then its build hook for each configured build config, then launches a `claude` session in a new tmux window running the project's review slash command.
The review command writes findings to the workspace in phases, committing after each phase.
When the review signals completion the window auto-closes, and if `AUTO_PUSH=1` the commits are pushed to the workspace's remote.

## More docs

- [docs/setup.md](docs/setup.md) - .env reference, podman, deploy keys and auto-push, webapp deployment, stopping/backups/debugging.
- [docs/adding-a-project.md](docs/adding-a-project.md) - hook contracts, project.yaml schema, PR polling, commit review, drift checking.
- [docs/workspace.md](docs/workspace.md) - the workspace repo contract: what to commit, what's gitignored, findings layout, migrating an old layout.
- [examples/workspace](examples/workspace) - a working reference workspace (postgres, pg_tde, psp projects) - read it alongside the docs above.
