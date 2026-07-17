# Patch Review Workspace

## Identity

You are working in CHANGEME's patch review workspace (GitHub: CHANGEME).
Fill this in: who reviews here, which upstream identities the reviews feed (mailing list name, GitHub handle), and any per-community conventions.
(for example: "Alice's patch review workspace (GitHub: alice)")

## Layout

Each reviewed project is self-contained under `<name>/` at this workspace's root.
A review reads and writes these per-project paths:

- `review/<topic>/` - patch worktree. `metadata.json` is the **normalized** topic metadata: `{project, topic, version, source_url, base_branch}`.
- `builds/<topic>/<config>/` - build artifacts (`status.yaml`, `logs/`, `install/`). `builds/master/<config>/` is the base build for comparison.
- `findings/<topic>/vNN/` - review output; `NN` = `version` from the metadata. Committed.
- `current-reviews/<topic>` - symlink to the active review's findings dir. When present the orchestrator set it; resolve and use it verbatim, do not recompute the version.

Adding or configuring a project - full layout, `project.yaml`, hook contracts, cross-project builds - is in `docs/adding-a-project.md` and `docs/workspace.md` in the infra repo (this workspace's parent directory).

## Conventions

- Review output always goes under the project's `findings/`, never in the review worktree.
- Each review version (vNN) is a self-contained directory with all findings for that patch iteration.
- Previous review versions are never modified - only the current version is written to.
- Commit review progress after completing each phase.
- Findings are generated locally as files only - never posted automatically to GitHub or mailing lists.
- Session auto-close is handled centrally by a Stop hook in `.claude/settings.json` (touches `$REVIEW_DONE_FILE` when the orchestrator set it) - review commands do not signal completion themselves. The hook signals completion only when no background work is in flight (`background_tasks`/`session_crons` empty), so a session paused waiting on a background agent is not treated as done.
