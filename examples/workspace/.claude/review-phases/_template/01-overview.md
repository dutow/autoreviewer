### Step 2: Initialize Output Directory

1. Create the output directory and subdirectories (the directory itself may already exist and be empty -- that is expected):
   ```
   <output directory>/
   <output directory>/patches/
   <output directory>/tests/
   ```
2. Copy all `.patch` and `.diff` files from `<PROJECT>/review/$ARGUMENTS/.hackorum/` to the `patches/` subdirectory
3. Check for previous versions: look for other `v*/` directories in `<PROJECT>/findings/$ARGUMENTS/` -- note the highest previous version path if it exists

### Step 3: Fetch Mailing List Discussion

Use WebFetch to download the `source_url` page and save the FULL content to `<PROJECT>/findings/$ARGUMENTS/v{version}/discussion.txt`.

**CRITICAL**: The mailing list thread may be very long.
You MUST save the complete fetched content to the file.
Do NOT truncate or summarize.
Fetch the content and write the full result to disk immediately.
If the fetch fails or content appears truncated, note this in `00-overview.md` and continue.

### Step 4: Check Build Status

Read `<PROJECT>/builds/$ARGUMENTS/*/status.yaml` for build/test results.
If tests failed, also read the relevant test logs from `<PROJECT>/builds/$ARGUMENTS/*/logs/test.log`.

### Step 5: Initial Commit

```
git add <PROJECT>/findings/$ARGUMENTS/v{version}/
git commit -m "review($ARGUMENTS): initialize v{version} review"
```

---

## Phase 1: Overview & Context -> `00-overview.md`

1. Read all patch files from the `patches/` subdirectory to understand what the patch does
2. Read `discussion.txt` -- this may be a VERY long file for long-running threads.
   Read it in this order:
   - FIRST: Read the END of the file (the most recent messages) -- these are the most relevant
   - THEN: Read the beginning for historical context
   - For long threads (>500 lines), use the Read tool with offset/limit to read in chunks, starting from the end
   - **CRITICAL**: Recent discussion (last 6-12 months) is MORE important than old discussion.
     If you must prioritize due to length, prioritize recent messages.
     Do NOT produce a summary that only covers old messages.
3. Read build/test status from the build status check
4. If a previous version directory exists, read its `05-summary.md`
5. Analyze the diff in the review worktree: run `cd <PROJECT>/review/$ARGUMENTS && git log --oneline master..HEAD` and `git diff master...HEAD --stat` to understand the scope
6. Classify the review complexity.
   Criteria (guidance, not a formula): diff size, number of subsystems touched, new abstractions or on-disk/protocol changes, controversy in the discussion.
   Also note whether this is the first reviewed version (no previous `v*` findings directory exists).

Write `<PROJECT>/findings/$ARGUMENTS/v{version}/00-overview.md`:

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

## Mailing List Discussion Summary

### Current Status (most recent messages)
[What is the current state of this patch on the mailing list?
Latest review feedback, author responses, committer comments.
Cover at minimum the last 6 months of discussion.]

### Discussion History
[Chronological summary of the full thread:
- Who participated and their roles (committer, reviewer, author, etc.)
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
which mailing list concerns were addressed]

## Review Complexity

**Classification:** TRIVIAL | MODERATE | COMPLEX
**First reviewed version:** yes | no

[One-paragraph justification referencing the criteria: diff size, subsystems
touched, new abstractions or on-disk/protocol changes, discussion controversy.]
```

Commit: `git add <PROJECT>/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add patch overview"`

---

