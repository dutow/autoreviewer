### Step 2: Initialize Output Directory

1. Create the output directory and subdirectories (the directory itself may already exist and be empty -- that is expected):
   ```
   <output directory>/
   <output directory>/patches/
   <output directory>/tests/
   ```
2. Generate the PR diff into `patches/`: read `base_branch` from metadata.json, then run `cd psp/review/$ARGUMENTS && git diff <base_branch>...HEAD > <output directory>/patches/pr.diff`
3. Check for previous versions: look for other `v*/` directories in `psp/findings/$ARGUMENTS/` -- note the highest previous version path if it exists

### Step 3: Load PR Discussion

The ingestion hook already wrote the full PR discussion (PR description, issue comments, reviews, and review-thread comments) to `psp/review/$ARGUMENTS/discussion.txt`.
Copy it to `<output directory>/discussion.txt`.
Do NOT fetch anything from the web.
If the file is missing, note it in `00-overview.md` and continue.

### Step 4: Check Build Status

Read `psp/builds/$ARGUMENTS/*/status.yaml` for build/test results.
If tests failed, also read the relevant test logs from `psp/builds/$ARGUMENTS/*/logs/test.log`.

### Step 5: Initial Commit

```
git add psp/findings/$ARGUMENTS/v{version}/
git commit -m "review($ARGUMENTS): initialize v{version} review"
```

---

## Phase 1: Overview & Context -> `00-overview.md`

1. Read all patch files from the `patches/` subdirectory to understand what the patch does
2. Read `discussion.txt` -- this may be a VERY long file for long-running PRs.
   Read it in this order:
   - FIRST: Read the END of the file (the most recent messages) -- these are the most relevant
   - THEN: Read the beginning for historical context
   - For long discussions (>500 lines), use the Read tool with offset/limit to read in chunks, starting from the end
   - **CRITICAL**: Recent discussion (last 6-12 months) is MORE important than old discussion.
     If you must prioritize due to length, prioritize recent messages.
     Do NOT produce a summary that only covers old messages.
3. Read build/test status from the build status check
4. If a previous version directory exists, read its `05-summary.md`
5. Analyze the diff in the review worktree (read `<base_branch>` from `metadata.json` (the PR's base branch)): run `cd psp/review/$ARGUMENTS && git log --oneline <base_branch>..HEAD` and `git diff <base_branch>...HEAD --stat` to understand the scope
6. Classify the review complexity.
   Criteria (guidance, not a formula): diff size, number of subsystems touched, new abstractions or on-disk/protocol changes, controversy in the discussion.
   Also note whether this is the first reviewed version (no previous `v*` findings directory exists).

Write `psp/findings/$ARGUMENTS/v{version}/00-overview.md`:

```markdown
# Patch Overview: $ARGUMENTS v{version}

## What This Patch Does
[Detailed description: what problem it solves, how it works, what subsystems
it touches, key design decisions made by the author.
Focus on the WHAT and WHY, not just the HOW.]

## Overall Vision & Architecture
[What is the high-level vision? How does the system behave differently after
this patch? What new capabilities or behaviors does it enable?

Then: how is this implemented -- what subsystems are modified, what new
abstractions are introduced, how data flows through the changed code.

Do NOT just list "commit 1 does X, commit 2 does Y" -- describe the
cohesive architectural picture that the patch creates.]

## PR Discussion Summary

### Current Status (most recent messages)
[What is the current state of this PR in the PR discussion?
Latest review feedback, author responses, maintainer comments.
Cover at minimum the last 6 months of discussion.]

### Discussion History
[Chronological summary of the full PR discussion:
- Who participated and their roles (maintainer, reviewer, author, etc.)
- What concerns were raised and by whom
- What was agreed upon
- What remains contested or unresolved
- Key technical points and decisions
- Review history across versions if applicable
- How the patch evolved over time]

## Build & Test Status
[Results from status.yaml -- did it build cleanly? Any test failures?
If tests failed, summarize what failed and why]

## Changes From Previous Version
[If applicable: what changed from the previous review version,
which concerns from our previous review were addressed,
which PR discussion concerns were addressed]

## Review Complexity

**Classification:** TRIVIAL | MODERATE | COMPLEX
**First reviewed version:** yes | no

[One-paragraph justification referencing the criteria: diff size, subsystems
touched, new abstractions or on-disk/protocol changes, discussion controversy.]
```

Commit: `git add psp/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add patch overview"`

---

