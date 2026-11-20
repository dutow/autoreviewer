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
- Completion is signalled by the runner: `bin/review-run` touches the done file when it ends, so review commands and phases do not signal completion themselves.
- Each phase of a queued review runs as a separate headless session. A phase must not start background agents or background tasks, and must wait for all its subagents to finish before it ends.
