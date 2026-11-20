# Adding a Project

Each reviewed project lives at the workspace root, `<name>/`, described by `<name>/project.yaml`.
Shared tooling (`bin/`, `.claude/`) lives at the workspace root too, and is reused across projects; a project only supplies config and, optionally, its own hooks.

This doc covers the hook contracts, `project.yaml` schema, and the steps to add a project - both from-scratch and GitHub-PR-flavored.
It does not cover the workspace repo's overall layout (see [workspace.md](workspace.md)) or runtime setup (see [setup.md](setup.md)).

## project.yaml

```yaml
name: <name>
base_branch: <branch>          # branch patches are diffed/built against
clone_url: <url>               # optional; upstream to seed master/ (task init-master)
ingestion: { hook: <name> }    # ingestion hook (project dir, workspace bin/, or infra bin/)
build:
  hook: <name>                 # build hook (project dir, workspace bin/, or infra bin/)
  default_config: <config>     # config file under <name>/configs/
  queue_configs: [<config>...] # configs the orchestrator builds per topic
review:
  command: <name>:review-patch # slash command, see .claude/commands/<name>/
  phases: <name>               # phase dir under .claude/review-phases/ (see Review phases)
  route: single                # route in its phases.yaml: single (default in the examples) or full
```

`review.phases` is required for the headless runner.
A project without it is still launched as an interactive claude session running `review.command`, with a warning in the queue log.
`review.route` defaults to `full` when unset.

## Hook resolution

A hook is referenced by bare name.
It is resolved in this order:

1. `<name>/<hook>` (project-local, in the workspace)
2. `workspace/bin/<hook>` (shared across this workspace's projects)
3. the infra repo's `bin/<hook>` (shipped with autoreviewer itself)

So project-specific hooks (e.g. postgres's `ingest`, `pg-build`) live in the project dir or workspace `bin/`; hooks reusable across any workspace (e.g. `github-pr`) live in the infra repo's `bin/` or the workspace's `bin/`.

## Hook contracts

### Ingestion hook

Invoked: `<hook> --project <name>/project.yaml <topic>`

Must populate `<name>/review/<topic>/` with the patch/diff files and a normalized `metadata.json`:

```json
{"project": "<name>", "topic": "<topic>", "version": <int>,
 "source_url": "<url>", "base_branch": "<branch>"}
```

The review command reads only this normalized file, so it is agnostic to the source (mailing list vs GitHub PR).

### Build hook

Invoked: `<hook> --project <name>/project.yaml <topic> <config>`

Must build `<topic>` using `<config>` (a file under `<name>/configs/`) into `<name>/builds/<topic>/<config>/` and write a `status.yaml` summarizing setup/build/install/test.

## Steps to add a project

1. `task new-project NAME=<name>` - copies `_template/` to `workspace/<name>/` (substituting `CHANGEME` for `<name>` in `project.yaml`), generates `workspace/.claude/commands/<name>/review-patch.md` from the `_git-pr` spine template (substituting `<PROJECT>`), and copies `workspace/.claude/review-phases/_git-pr/` to `workspace/.claude/review-phases/<name>/` (substituting `<PROJECT>`).
2. Edit `workspace/<name>/project.yaml`: `base_branch`, `ingestion.hook`, `build.hook`/`default_config`/`queue_configs`, `review.command`, `review.phases`, `review.route`.
   For a GitHub-PR project also add `source: <owner/repo>` and `topic_prefix: pr` (see below).
3. Add build configs under `workspace/<name>/configs/`.
4. Provide the build hook: reuse a `bin/` hook or add a project-local one.
5. Fill in the review command's marked regions (review context, review criteria, test-case kind, validation environment), and the same regions in the phase files - see drift check below for GitHub-PR projects; mailing-list-style projects hand-edit `.claude/commands/<name>/review-patch.md` directly.
6. Seed the master checkout. GitHub-PR projects create `master/` automatically at ingest time (see the github-pr contract below), so skip this. Mailing-list projects (postgres-style) need it before the first ingest: set `clone_url` in `project.yaml` and run `task init-master PROJ=<name>` - a one-shot, idempotent clone into `workspace/<name>/master`.
7. `task claude` - opens an interactive claude session in the workspace, cwd `workspace/`.
   Use it to develop and verify the build hook against a real topic before wiring it into the queue.
8. Enqueue work: `task enqueue -- <name> <topic>`, or for a GitHub-PR project bootstrap every currently-open PR at once with `../bin/enqueue-open-prs <name>` (run inside the container, e.g. via `task shell`, which lands you in `workspace/`).

### Completion signal (auto-close)

The orchestrator runs each review in a tmux window and arms a watcher that closes the window ~120s after a sentinel file appears.
The window runs `bin/review-run --done-file <sentinel> ...`, and the runner touches the sentinel when it ends, success or failure.
Each launch gets its own sentinel path, and the watcher closes the window by its tmux id, so re-queueing a topic while an older run of it finishes is safe.
A new review command or phase needs no completion step of its own.

The workspace `Stop` hook in `workspace/.claude/settings.json` touches `$REVIEW_DONE_FILE` only when that variable is set.
That is the case just for the interactive fallback (a project without `review.phases`).
Phase sessions run without it, so one finished phase never closes the window.
Phase sessions have `REVIEW_RUN=1` instead; a hook that should act in every review session, like the `PermissionRequest` auto-allow, checks `[ -n "$REVIEW_DONE_FILE$REVIEW_RUN" ]`.

A usage-limit hit does not end the review: the runner waits for the reset and retries (see [setup.md](setup.md#usage-limit-pause)).

## Review phases

The runner reads the phase definitions from `workspace/.claude/review-phases/<name>/`, where `<name>` is `review.phases`:

- `phases.yaml` - the manifest.
- `shared.md` - text prepended to the prompt of every phase with `shared: true` (review context for the project).
- numbered phase files, `01-overview.md` ... - one prompt per phase.

Each phase runs as its own headless `claude -p` session.
The prompt is a header (project, topic, version, phase, output directory, review worktree, previous reviewed version) followed by `shared.md` (if the phase asks for it) and the phase file.
Phase files may start with frontmatter, which is dropped.
`$ARGUMENTS` (the topic), `$OUTDIR` (the findings dir) and `$PROJECT` are replaced in the text.
The header tells the phase to run only that phase, not to start background agents or background tasks, and to wait for every subagent before it ends.

### phases.yaml

```yaml
default_model: opus            # optional; per-phase `model` overrides
default_effort: high           # optional; per-phase `effort` overrides
routes:
  single:                      # the old one-session command, run headless
  - name: review
    prompt: "../../commands/<name>/review-patch.md"
    output: 05-summary.md
  full:                        # one session per phase
  - name: overview
    prompt: 01-overview.md     # relative to this dir
    output: 00-overview.md     # file in the findings dir
  - name: design
    prompt: 02-design.md
    output: 01-design-review.md
    shared: true               # prepend shared.md
  - name: reply
    prompt: 07-reply.md
    output: 06-reply-draft.md
    skip_if:                   # skip when this file matches
      file: 05-summary.md
      match: "^\\*\\*Post:\\*\\* (nothing to post|moot)"
```

Phase keys: `name` and `prompt` (required, `name` unique within a route), `output`, `model`, `effort`, `shared`, `skip_if` (`file` in the findings dir plus a `match` regexp).
A missing prompt file, a duplicate phase name or an unknown route fails the run before claude starts.

After a phase ends, `output` must exist in the findings dir, or the phase fails.
The runner commits it if the phase did not.
A failed phase stops the review.
The runner calls `bin/findings-metadata` (which writes `metadata.json` in the findings dir) at the start and the end of the run.

### Routes

- `single` - the existing review command run as one headless session.
  The phase's `prompt` points at the command file, so the review behaves as before, and the run still gets logs and `usage.json`.
- `full` - one session per phase, each with a focused prompt.
  It is off until a quality check against `single` shows the findings hold up, so the examples set `route: single`.

Switch a project by changing `review.route`, or try one run with `bin/review-run --route full <project> <topic>` (see [setup.md](setup.md#running-by-hand)).
`bin/review-run --render <phase> <project> <topic>` shows the exact prompt a phase gets.

## Git-PR projects (psp, pg_tde, ...)

Projects reviewed from GitHub PRs use the shared `bin/github-pr` ingestion hook and set two extra `project.yaml` fields:

- `source: <owner/repo>` - the GitHub repo (used by `gh`).
- `topic_prefix: pr` - bare numeric topics are prefixed with `pr` (e.g. `enqueue psp 123` -> `psp pr123`).
  Postgres keeps the default `t`.

`base_branch` in `project.yaml` is only a default/fallback.
The real review base is **the PR's base branch**, fetched from GitHub at ingest time and written into `metadata.json` (`base_branch`).
All diff/build/review logic reads it from there.

### github-pr ingestion contract

Invoked `bin/github-pr --project <project.yaml> pr<N>`.
It:
- fetches the PR base branch and `pull/<N>/head` into `master/`,
- creates `review/pr<N>/` as a detached worktree at the PR head,
- writes `review/pr<N>/discussion.txt` (PR body + comments + reviews + review threads, via `gh`),
- writes normalized `metadata.json` (`project, topic, version, source_url, base_branch, pr_number, head_sha`); `version` = max existing `findings/pr<N>/v*` + 1.

Requires `gh` authenticated (`gh auth login` or `GH_TOKEN`).

### Command template and drift check

The per-project review commands under `workspace/.claude/commands/<name>/review-patch.md` are hand-maintained copies of `workspace/.claude/commands/_git-pr/review-patch.md`.
The phase dirs `workspace/.claude/review-phases/<name>/` are copies of `workspace/.claude/review-phases/_git-pr/` and follow the same rules.
Only the regions between `<!-- project-specific:start -->` and `<!-- project-specific:end -->` markers may differ per project; everything else - the spine - must match the template with `<PROJECT>` substituted.

There are **four** marked regions, in file order:

1. **R1 - review context.**
   Project idioms the reviewer must know to avoid false positives.
2. **R2 - Phase 3 review criteria.**
   The bullet list the code review is run against.
3. **R3 - Phase 4 test-case kind.**
   What a validation subagent should write (SQL/TAP for Postgres projects; a shell script driving the binary, or C, for a non-Postgres project).
4. **R4 - validation environment.**
   How to get a runnable artifact - a PG server for the Postgres projects; a built binary plus scratch setup for others.

The template holds placeholders in all four; each project holds the real content.

`bin/check-command-drift` verifies this (exit 1 + diff on drift).
It derives the list of projects to check by scanning `workspace/*/project.yaml` for `ingestion.hook: github-pr` - no hardcoded project list to maintain.
It compares each against the spine template at `workspace/.claude/commands/_git-pr/review-patch.md`.
It also compares every file in the project's phase dir against the same file in `review-phases/_git-pr/` (spine only, `<PROJECT>` substituted), and reports a missing phase dir or file (`MISSING`) and a file the template does not have (`EXTRA`) as drift.
The check runs automatically (non-fatal, warning only) at `review-queue` startup, so drift surfaces without a separate CI step.

When editing the review pipeline, edit the templates first (the command and the phase files), propagate to each project, and rerun the check (`bin/check-command-drift`).

The postgres commands (`postgres/review-patch.md`, `postgres/review-commits.md`), the postgres phase dir and the mailing-list skeleton (`_template/review-patch.md`) are hand-maintained and outside the check - mirror spine changes into them manually.

### Cross-project build dependency (pg_tde -> PSP)

Some extension projects build against another project's install rather than standing alone.
`pg_tde` is the worked example: its build hook (`pg_tde-build`) builds and tests pg_tde against a Percona Server for PostgreSQL (`psp`) install, resolved by convention from each config's `psp_branch`/`psp_config`: `psp/builds/<psp_branch>/<psp_config>/install`.
If that install is missing, the hook builds it first via `bin/pg-build`, then builds pg_tde with `-Dpg_config=<install>/bin/pg_config` and runs `meson test` against it.
The PSP install must be a full meson install so `pgxs/src/test/{regress,perl}` are present for pg_tde's TAP tests.

`psp/master/` must exist first - seed it with `task init-master PROJ=psp` (or clone it by hand) before running a pg_tde build or review.
Both `pg_tde` and `psp` ship as reference projects in `examples/workspace/`.

### Automatic PR polling

Add a `poll` block to `project.yaml` to opt in to automatic re-review when a PR's head commit changes:

```yaml
poll:
  enabled: true
```

When `review-queue` starts and at least one project has polling enabled, it spawns `bin/review-poll` in a tmux window named `poller` (in the `reviews` session).

The poller wakes every `REVIEW_POLL_INTERVAL` seconds (default: 180) and, for each enabled project with a `source`, checks all open PRs via `gh`.
If a PR's `head_sha` changed since it was last enqueued, the PR is re-enqueued.
Only new commits trigger a re-review - comments and review threads are ignored.

To re-review only PRs you have already reviewed, add `only_reviewed: true` to the `poll` block.
A changed or new PR is then enqueued only if `<name>/findings/<topic>/` exists; otherwise its head is recorded and skipped.
Once you review such a PR by hand (`task enqueue`), its later pushes are polled like any other.

On first run the poller silently baselines: it records the current head shas for all open PRs and enqueues nothing.
Only subsequent new commits or brand-new PRs are picked up from that point on.

### Bootstrapping a project's existing open PRs

Because the poller baselines silently, PRs that were already open when a project is added are never enqueued automatically.
Queue them once with:

```bash
../bin/enqueue-open-prs <project> [--dry-run]
```

(run inside the container - `task shell` lands you in `workspace/`, then `../bin/enqueue-open-prs ...`).
It reads `source` and `topic_prefix` from the project's `project.yaml`, lists open PRs via `gh`, and enqueues each one.
Safe to run before or after the poller's first cycle - the baseline enqueues nothing either way, so there is no double-processing.

This is deliberately a one-shot command rather than a `project.yaml` flag: a declarative "enqueue existing on baseline" option would re-enqueue every open PR whenever the poll state file is lost or corrupted.

State is tracked in `state/poll.state` at the infra repo root (override with `REVIEW_POLL_STATE`).
This file is gitignored (it lives under `state/`, not in the workspace).

### Hackorum polling (postgres)

Mailing-list projects can be fed from the [hackorum](https://hackorum.dev/help/api) event feed instead of manual `task enqueue`:

```yaml
poll:
  enabled: true
  hackorum: true
  only_reviewed: false   # optional
```

Each poll cycle reads `branch.created` events from `https://hackorum.dev/api/v1/events` (`HACKORUM_API` overrides the API base URL, default `https://hackorum.dev/api/v1`).
Hackorum emits one per patchset version on its first apply attempt; rebases are not re-reported, so they never trigger a review.
A branch `t<id>_<N>` that applied and was pushed to GitHub enqueues topic `t<id>` (version `N`).
Branches that failed to apply are skipped.
Applied but not yet pushed branches are kept pending and rechecked each cycle for up to 24h.

A version is skipped when `findings/t<id>/v<N>` already exists or a version `>= N` was already enqueued by the poller.
A topic that is already waiting in the queue (a line after the one currently being processed) is not enqueued again, and neither is one enqueued earlier in the same cycle: ingest always takes the latest patchset, so one queued review covers every version that arrived meanwhile.
With `only_reviewed: true`, only topics that already have `findings/t<id>/` are enqueued.

On first run the poller baselines at the current time and enqueues nothing: the backlog is never processed.
If the stored cursor is older than hackorum's 90-day retention (`cursor_expired`), it re-baselines the same way.
API errors skip the hackorum step for that cycle; the cursor only advances after a page is fully processed.

State lives in `state/poll.state` under `<project>.hackorum` (`cursor`, `pending`, `enqueued`).

### Base-branch refresh

Each poll cycle, before checking PRs, `review-poll` refreshes every poll-enabled project's base branch(es): `git fetch origin <base>` then force the local ref to `origin/<base>` - `reset --hard` when that branch is checked out (e.g. postgres `master/`), `branch -f` when the checkout is detached (e.g. the GitHub-PR host).
The base is treated as a canonical upstream mirror; local edits on it are discarded.

- GitHub-PR projects refresh the distinct set of open-PR base branches (from `baseRefName`) unioned with `base_branch`.
- A project with `poll.enabled: true` and **no** `source` (e.g. postgres) is *refresh-only*: its base is refreshed every cycle, but it polls no PRs and stores no PR state.
  `state/poll.state` still holds its commit-review and hackorum state when those are enabled.

Because of this, `poll.enabled` only requires a `base_branch`; `source` is optional.

### Commit review (optional)

A project may add a `commit_review` section to `project.yaml` to get triage reviews of new `base_branch` commits.
Requires `poll.enabled: true`.

```yaml
commit_review:
  command: <name>:review-commits
  window: "02:00-05:00"   # local-time enqueue window (default shown)
  max_batch: 10           # max commits per session (default shown)
```

When the base-branch refresh pulls in new commits, the poller checks whether to enqueue a batch: only if the current local time falls inside the configured `window` AND at least 20 hours have passed since the last batch was enqueued (use `REVIEW_POLL_COMMITS_NOW=1` to bypass both for testing).
On first enablement, the poller baselines to `HEAD~20`, so the first batch covers up to 20 existing commits.

Each batch enqueues `<project> commits <from>..<to>` with at most `max_batch` commits per session.
The queue launches `bin/review-run --commits <project> <from>..<to>`, which runs the `command` (a slash command like `<name>:review-commits`) as one headless session on the refreshed base checkout - no ingest and no build step.
Commit reviews always run on opus, have no phases, and log to `state/logs/<project>-commits-<from>-<to>/commits.jsonl` and `state/usage.log`.

The ledger `<name>/commit-reviews.log` (gitignored) records each reviewed commit: one line per commit, format `<timestamp> <sha> CLEAN|FLAGGED <subject>`.
The poller's own progress is tracked in `state/poll.state`.

## Generic build hooks (reference, from the example workspace)

These live in `examples/workspace/bin/` and are worth knowing about before writing a new build hook from scratch.

### Generic PGXS extension builds (`ext-build`)

`bin/ext-build` is a reusable hook for **standalone PGXS extensions** - those whose `meson.build` only works in-tree (it references `contrib_mod_args` &c.) but whose `Makefile` builds standalone via `make PG_CONFIG=<pg_config>`.
Like `pg_tde-build` it resolves a PSP install by convention from each config's `psp_branch`/`psp_config` (auto-building it via `bin/pg-build` if missing) and installs the module into that PSP install.
It exports the checked-out tree (PR head or master tip) into the build dir via `git archive` so the review worktree stays clean.

Config keys (`<name>/configs/<config>.yaml`): `psp_branch`, `psp_config` (required), `make_args` (extra make vars), `run_tests` (run `make installcheck` - needs a running server; default false).

**C++ caveat:** a meson-built PSP install ships an empty `CXX`/`CXXFLAGS` in its pgxs `Makefile.global` (PG's meson build doesn't export C++ vars for PGXS), so a C++ extension won't compile unless the config passes them explicitly.

### Stable-branch base builds (`pg-build`)

`bin/pg-build` builds three source kinds: `master`, a review topic (`review/<topic>`), or a **branch name** - the latter creates a detached worktree under `<name>/branches/<branch>` and builds into `builds/<branch>/<config>/`.
This is how a stable-branch install (e.g. a psp stable branch that pg_tde consumes) gets built without being a review topic itself.
