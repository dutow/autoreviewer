# The Workspace Repo

The workspace (`workspace/`, gitignored in this repo) is a separate git repo:
your data and config.
This doc describes its contract - what belongs in it, what's derived/gitignored, and how findings are laid out.

Does not cover: how to add a project inside the workspace (see [adding-a-project.md](adding-a-project.md)) or day-to-day operation (see [setup.md](setup.md)).

Starting fresh, with no workspace repo of your own yet?
`task init-workspace` seeds `workspace/` from `examples/workspace/` and git-inits it, so you have a working reference to diverge from instead of starting blank.

## Privacy

This repo holds everything sensitive: which patches/PRs you reviewed, your review prompts and criteria, and every finding you've ever written.
Keep it private unless you deliberately decide otherwise.

## What to commit

At the workspace root:

- `<name>/project.yaml` - one per reviewed project.
- `<name>/` hooks - project-local ingestion/build scripts.
- `<name>/configs/` - build configuration YAML files.
- `<name>/findings/` - review output (see below).
- `Taskfile.yml` - optional per-project task helpers (e.g. the postgres cluster start/stop/psql tasks).
- `.claude/commands/` - review slash commands, per project, plus the `_git-pr` spine template and `_template` skeleton.
- `CLAUDE.md` - identity and layout notes for claude sessions run in this workspace (see below).
- `Dockerfile` - optional, adds project build deps to the queue image (see below).
- `bin/` - workspace-shared hooks and vendored tools.
- `public/` - optional, static files the webapp serves as-is at `/public/` (see [setup.md](setup.md#static-files)).
  Commit the contents or gitignore the big downloads, your call.

## Gitignored

Per the example `.gitignore` (`examples/workspace/.gitignore`):

```
*/master
*/review
*/builds
*/branches
*/current-reviews
/current-reviews
*/commit-reviews.log
```

These are either derived (checkouts, build output) or local run state (worktrees, the current-review symlink, the commit-review ledger) - none of it is meant to travel with the repo.

The workspace-root `current-reviews/` is a directory of per-project symlinks into each project's own `current-reviews/`.
It's rebuilt by the infra script `bin/refresh-current-reviews` - run it by hand if the tree gets out of sync (e.g. after adding a project or pruning findings).

## Findings layout

`<name>/findings/<topic>/vNN/` - `NN` is the `version` from the topic's normalized `metadata.json`.
Each version directory is immutable once written: previous versions are never edited, only the current one.

- `metadata.json` - a committed copy of the topic metadata (title, source_url, reviewed_at, etc.) for the web frontend.
  Written by `bin/findings-metadata` (called by the queue and by review commands), or `bin/findings-metadata --backfill` for existing history.
- The review command's phase output files (overview, design review, code review, validated findings, PR discussion cross-reference, summary, `patches/`, `tests/`, `discussion.txt`).

The agent commits review progress after completing each phase - so a review's history is visible in the workspace's git log, not just its final state.

## The workspace Dockerfile pattern

Project builds often need system packages the base autoreviewer image doesn't carry (compilers, meson, dev headers, ...).
Rather than bloating the shared base image, the workspace supplies its own Dockerfile layered on top:

```dockerfile
FROM autoreviewer-base:local

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    <your build deps> \
 && rm -rf /var/lib/apt/lists/*
USER reviewer
```

Enable it with `QUEUE_DOCKERFILE=workspace/Dockerfile` in `.env`, then `task build`.
See `examples/workspace/Dockerfile` for the Postgres/meson build-dependency list used by the reference projects.

## CLAUDE.md identity block

`CLAUDE.md` at the workspace root is read by every claude session run in the workspace (interactive `task claude` and queued reviews alike).
Fill in the identity block at the top: who you are, which forge/mailing-list identity the reviews feed under, and any per-community conventions worth the agent knowing up front.
See `examples/workspace/CLAUDE.md` for the placeholder and the rest of the layout notes it documents.

## Migrating a pre-split workspace

If you're coming from an older single-repo layout where everything lived under one repo's `projects/<name>/` and `bin/`/`.claude/` at that repo's root:

1. Promote each `projects/<name>/` up to `<name>/` at the new workspace repo's root (drop the `projects/` prefix).
2. Delete the old infra files from that repo (Taskfile, compose files, Dockerfile, webapp, etc.) - those now live only in this infra repo, not duplicated into the workspace.
3. Apply the same `projects/<name>/` -> `<name>/` path fix inside your `.claude/commands/*.md` files - anywhere they reference project paths.
   The example workspace's commands already have this fix applied; diff against them if unsure.
4. Copy `Dockerfile` and `bin/` hooks from `examples/workspace/` as a starting point for the pieces that used to be assumed/shared and now need to be explicit in your workspace.
5. `git init` (or keep your existing history if you're restructuring the same repo) and check it out at `workspace/` next to this infra repo.
