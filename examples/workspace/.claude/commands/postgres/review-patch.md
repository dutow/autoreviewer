---
description: "Run automated review of a PostgreSQL patch topic"
---

# Automated PostgreSQL Patch Review

You are conducting a thorough, automated review of a PostgreSQL patch.
Run the full 6-phase pipeline below without stopping for user input.
Commit after each phase.

## Setup

The topic to review is: `$ARGUMENTS`

### Step 1: Validate Inputs

1. Verify `postgres/review/$ARGUMENTS/` exists -- if not, stop with an error telling the user to run the ingestion hook (`postgres/ingest --project postgres/project.yaml $ARGUMENTS`) first
2. Verify `postgres/review/$ARGUMENTS/metadata.json` exists -- if not, stop with an error telling the user to run the ingestion hook (`postgres/ingest --project postgres/project.yaml $ARGUMENTS`) first
3. Read `postgres/review/$ARGUMENTS/metadata.json` and extract:
   - `version` -> this is the version number (NN)
   - `source_url` -> mailing list thread URL
   - `topic` -> canonical topic id
4. Set the output directory:
   - **If `postgres/current-reviews/$ARGUMENTS` exists as a symlink**, the orchestrator has already created and reserved the output directory for you.
     Resolve the symlink and use its target as the output directory -- do NOT recompute the version number or pick a different directory.
     This is the authoritative path; using it avoids numbering drift.
   - **Otherwise** (running this command manually), set the output directory to `postgres/findings/$ARGUMENTS/v{version}/`, then create a relative symlink `postgres/current-reviews/$ARGUMENTS` -> `../findings/$ARGUMENTS/v{version}` so the active review is tracked under `postgres/current-reviews/` (create `postgres/current-reviews/` if it does not exist).

   In the steps below, "the output directory" refers to whichever path you resolved here.

### Step 2: Initialize Output Directory

1. Create the output directory and subdirectories (the directory itself may already exist and be empty -- that is expected):
   ```
   <output directory>/
   <output directory>/patches/
   <output directory>/tests/
   ```
2. Copy all `.patch` and `.diff` files from `postgres/review/$ARGUMENTS/.hackorum/` to the `patches/` subdirectory
3. Check for previous versions: look for other `v*/` directories in `postgres/findings/$ARGUMENTS/` -- note the highest previous version path if it exists
4. Write the committed review metadata (idempotent; safe if the orchestrator already ran it):
   `../bin/findings-metadata --project postgres/project.yaml $ARGUMENTS`

### Step 3: Fetch Mailing List Discussion

Use WebFetch to download the `source_url` page and save the FULL content to `postgres/findings/$ARGUMENTS/v{version}/discussion.txt`.

**CRITICAL**: The mailing list thread may be very long.
You MUST save the complete fetched content to the file.
Do NOT truncate or summarize.
Fetch the content and write the full result to disk immediately.
If the fetch fails or content appears truncated, note this in `00-overview.md` and continue.

### Step 4: Check Build Status

Read `postgres/builds/$ARGUMENTS/*/status.yaml` for build/test results.
If tests failed, also read the relevant test logs from `postgres/builds/$ARGUMENTS/*/logs/test.log`.

### Step 5: Initial Commit

```
git add postgres/findings/$ARGUMENTS/v{version}/
git commit -m "review($ARGUMENTS): initialize v{version} review"
```

---

## PostgreSQL Review Context

When reviewing PostgreSQL code, keep these idioms in mind to avoid false positives:

1. **Memory contexts (MemoryContext)**: PostgreSQL uses hierarchical memory contexts.
   `palloc()` allocates in the current context, freed when that context is destroyed.
   Don't flag "missing free" for palloc'd memory in transaction or statement contexts -- it's freed automatically.

2. **ereport/elog with ERROR or higher**: These `longjmp()` out of the current execution.
   Code after `ereport(ERROR, ...)` is unreachable.
   Don't flag "missing return after error."

3. **PG_TRY/PG_CATCH**: Exception handling via `setjmp/longjmp`.
   Resource cleanup goes in `PG_CATCH` or `PG_FINALLY` blocks.

4. **Buffer pins and locks**: `LockBuffer()`, `ReleaseBuffer()`.
   The pin/lock protocol is critical -- look for mismatches but understand some code intentionally holds pins across operations.

5. **Critical sections**: `START_CRIT_SECTION()` / `END_CRIT_SECTION()`.
   Between these, any ERROR becomes PANIC.
   WAL logging happens inside critical sections.

6. **LWLock vs heavyweight locks**: LWLocks are lightweight, short-duration.
   Regular (heavyweight) locks support deadlock detection.
   Different mechanisms with different semantics.

7. **Catalog update patterns**: System catalog changes follow specific patterns with `CatalogTupleInsert` / `CatalogTupleUpdate` / `CatalogTupleDelete`.

8. **GUC (Grand Unified Configuration)**: Configuration variables.
   New GUCs need correct types, bounds, contexts, and flags.

9. **WAL (Write-Ahead Logging)**: Data modifications must be WAL-logged for crash recovery.
   WAL record contents must match actual page modifications.

10. **1-based indexing**: PostgreSQL uses 1-based for attribute numbers, parameter positions.
    Arrays are 0-based.
    Mixing these up is a common bug source.

11. **StringInfo**: String buffer API -- `initStringInfo`, `appendStringInfo`, `appendStringInfoChar`.
    Don't flag manual string handling when StringInfo is the convention.

12. **List API**: PostgreSQL's linked list implementation using `List *`, `lappend()`, `foreach()`.
    Not a C standard library list.

13. **ResourceOwner**: Tracks resources (buffer pins, catcache refs, etc.) owned by a transaction or subtransaction.
    Resources are auto-released on transaction abort.

---

## Severity Definitions

- **BUG** -- Almost certainly a bug.
  Wrong behavior, crash, data corruption.
- **LIKELY_BUG** -- Probably a bug but could be intentional in context not visible in the diff.
- **SUSPICIOUS** -- Looks wrong but might be correct; needs human review.
- **RISKY** -- Not wrong now but fragile, likely to cause bugs during future maintenance.
- **NITPICK** -- Correct observation but below the posting bar: style, comment wording, code organization, speculative coverage gaps.
  Kept for the record, not recommended for posting.
- **TYPO** -- User-visible typo in error messages, SQL function names, GUC names, documentation strings shown to users.

Every `**Severity:**` line in every output file must contain exactly one of these six values and nothing else -- no parenthetical qualifiers, no arrows, no invented labels (MINOR, LOW, etc.).
Reclassification notes belong in the finding body, never on the severity line.

---

## Citation Requirements

Every finding MUST include citations:

**When referring to the patch under review:**
- Format: `patch: path/to/file.c:123` or `patch: path/to/file.c:123-145` for ranges
- Quote the relevant code snippet

**When referring to existing PostgreSQL code (for comparison/examples):**
- Format: `src: path/to/file.c:123`
- Explain why this is the authoritative example to follow

**When referring to mailing list discussions:**
- Reference the message author and approximate date
- Quote the relevant point

For each finding:
1. Cite the specific location in the patch
2. Explain why it is a problem
3. Cite existing PostgreSQL code or documentation demonstrating the correct approach
4. Suggest a specific fix

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
5. Analyze the diff in the review worktree: run `cd postgres/review/$ARGUMENTS && git log --oneline <base_commit>..HEAD` and `git diff <base_commit>..HEAD --stat` to understand the scope (`base_commit` from `metadata.json`; `master/` may be at a different commit)
6. Classify the review complexity.
   Criteria (guidance, not a formula): diff size, number of subsystems touched, new abstractions or on-disk/protocol changes, controversy in the discussion.
   Also note whether this is the first reviewed version (no previous `v*` findings directory exists).

Write `postgres/findings/$ARGUMENTS/v{version}/00-overview.md`:

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

Commit: `git add postgres/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add patch overview"`

---

## Phase 2: Design & Approach Review -> `01-design-review.md`

With the full context from Phase 1, evaluate the patch's overall design and approach.
Use subagents to read relevant existing PostgreSQL code in `master/` to understand the current architecture in affected areas.

Scale this phase to the complexity classification from Phase 1:

- **TRIVIAL**: write a short design note instead of the full template: Problem Assessment (1-2 sentences), Approach Evaluation (one paragraph -- "there is only one reasonable fix" is an acceptable conclusion when true), and Design Concerns.
  Omit the other sections.
- **MODERATE**: use the full template below.
- **COMPLEX and first reviewed version**: before writing the review, run an alternatives exploration.
  Dispatch 2-3 parallel subagents -- one per applicable angle (drop an angle only if it clearly does not apply):
  1. narrower scope -- could a subset of this feature solve the core problem?
  2. different layer or mechanism -- could the same goal be reached in another subsystem or with a different primitive?
  3. reuse -- does existing infrastructure already provide most of this?

  Each subagent prompt must include: what the patch does (from Phase 1), its assigned angle, and this task: "Sketch a concrete alternative design from your angle.
  Read the relevant existing code in `master/` to ground it.
  Return: the sketch, its feasibility, and its trade-offs versus the patch's approach.
  Be willing to conclude the patch's approach is better -- say so and why."

  Write the results as an `### Alternatives Considered` subsection under Approach Evaluation, comparing each alternative against the patch's approach, and flag any design questions worth raising on the mailing list.
- **COMPLEX, later rounds**: carry the previous version's design review forward and focus on what changed -- tag each item as carried-over or new.

The fenced template below shows the full MODERATE/COMPLEX form.
For TRIVIAL patches, emit only the three-section short note described above -- do not fill in the omitted sections.

Write `postgres/findings/$ARGUMENTS/v{version}/01-design-review.md`:

```markdown
# Design Review: $ARGUMENTS v{version}

## Problem Assessment
[Is the problem this patch solves real and worth solving?
Is it well-defined? Is there consensus that it needs solving?]

## High-Level Vision
[What is the overall vision of this change? Not "what commits does it contain"
but: what is the end-state this patch creates? How does the system behave
differently after this patch? What new capabilities does it enable?
What is the mental model the author is building?]

## Approach Evaluation
[Is this the right approach to the problem?
What are the alternatives the author could have taken?
What trade-offs does this approach make?
Why might the author have chosen this approach over alternatives?
Could the same goal be achieved with a simpler or different design?]

## Architectural Fit
[Does this fit well with PostgreSQL's existing architecture?
Does it follow established patterns in the codebase?
Does it introduce new abstractions -- are they justified?
Does it modify existing abstractions -- is this appropriate?
How does it interact with related subsystems?]

## Scope Assessment
[Is the change minimal and focused, or does it try to do too much?
Are there missing pieces that should be included?]

## Design Concerns
[Any fundamental issues with the design itself, independent of implementation quality.
These are issues that can't be fixed by editing code -- they require rethinking the approach.]
```

Commit: `git add postgres/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add design review"`

---

## Phase 3: Deep Code Review -> `02-code-review.md`

Perform a thorough, line-by-line review of the entire patch.
This is the most detailed phase.

Use subagents to:
- Find similar patterns in the PostgreSQL codebase (in `master/`) to compare against
- Look up how similar problems are solved elsewhere in the code
- Verify coding conventions against existing examples
- Read header files and related source files for context on data structures and calling conventions

Review the patch against ALL of these criteria:
- **Logic correctness** -- does the code actually do what the patch claims?
- **Memory safety** -- proper palloc/pfree, memory context usage, no leaks in error paths (accounting for PG's memory context auto-cleanup)
- **Locking** -- correct lock types, lock ordering (deadlock prevention), held across appropriate scope
- **Error handling** -- all error paths clean up properly, no resource leaks, correct ereport usage
- **Signal/interrupt safety** -- CHECK_FOR_INTERRUPTS in long loops, async-signal-safe where required
- **Security** -- no injection vectors, proper privilege checks, correct ACL enforcement
- **Concurrency** -- race conditions, visibility of shared state, correct use of memory barriers
- **PostgreSQL conventions** -- coding style, error message format (primary/detail/hint, appropriate ERRCODE), memory context usage, API usage (StringInfo, List, etc.)
- **Performance** -- unnecessary allocations, copies, or repeated work in hot paths
- **Completeness** -- regression tests included and sufficient, documentation updates, catalog upgrade path if needed

### What NOT to flag

Do not write findings for:

- Comment-wording suggestions on text that is otherwise accurate ("comment could mention X"), especially wording already settled in the discussion
- Code-organization or placement preferences (function order, file layout, header sorting)
- Deliberate trade-offs the patch, commit message, or discussion already explains
- "Correct, noted for completeness" observations -- if the code is fine, there is no finding
- Test-coverage gaps that do not name a specific failure (see below)

A clean patch yielding few or zero findings is the expected outcome, not a failure.
Do not manufacture findings to fill the report.

**Test-coverage findings:** a missing-test finding must name the specific failure or regression the missing test would catch -- ideally you write and run that test during validation.
A coverage observation that names a concrete but unverified failure may be recorded at NITPICK severity; one that names no specific failure is omitted entirely.

"What NOT to flag" takes precedence over NITPICK: if an observation matches the list above, omit it entirely -- do not record it as a NITPICK finding.
NITPICK is for observations that clear this bar but still fall below the posting bar.

Write `postgres/findings/$ARGUMENTS/v{version}/02-code-review.md`:

```markdown
# Code Review: $ARGUMENTS v{version}

## Review Scope
[Files reviewed, total lines changed, approach taken]

## Findings

### Finding: [short descriptive title]

**Severity:** BUG | LIKELY_BUG | SUSPICIOUS | RISKY | NITPICK | TYPO
**Location:** `patch: path/to/file.c:123-145`

**Description:**
[What the issue is, why it matters]

**Evidence:**
[Code snippets from the patch, references to master code showing correct patterns]
[Use `src: path/to/file.c:123` for existing PG code citations]

**Suggested Fix:**
[Specific code change or approach to fix the issue]

[... repeat for each finding ...]
```

Commit: `git add postgres/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add code review findings"`

---

## Phase 4: Finding Validation -> `03-review-validated.md`

This phase validates each non-trivial finding using parallel subagents.

### Step 1: Categorize Findings

Read `02-code-review.md` and separate findings into:
- **Trivial** (skip validation): TYPO or NITPICK severity, or findings that are self-evidently correct (obvious null deref with clear evidence, straightforward off-by-one with line numbers)
- **Non-trivial** (must validate): Everything else

### Step 2: Dispatch Parallel Validation Subagents

For each non-trivial finding, dispatch a validation subagent using the Agent tool.
Launch all validators in parallel -- they are fully independent.

**IMPORTANT**: Each subagent prompt must contain the FULL finding text.
Do not make subagents read files -- paste the finding directly into the prompt.

Use this prompt template for each validation subagent:

---

**Validation Subagent Prompt:**

```
You are validating a specific finding from a PostgreSQL patch review.
Working directory: the workspace root

## PostgreSQL Context

[Include the full "PostgreSQL Review Context" section AND the full Severity Definitions section (including the exact-enum rule) from above]

## The Finding To Validate

[PASTE THE FULL FINDING TEXT HERE -- title, severity, location, description, evidence, suggested fix]

## Your Task

Deeply validate whether this finding is real and correctly assessed.

### 1. Read the Code

- Read the relevant patch code in `postgres/review/$ARGUMENTS/`
- Read the corresponding code in `master/` for comparison
- Read surrounding context: callers, callees, header files, related functions

### 2. Trace the Code Path

- Build a concrete call stack showing how the problematic code is reached
- Identify ALL callers of the affected function(s)
- Determine under what conditions the problematic path is taken

### 3. Construct a Concrete Scenario

- Describe a SPECIFIC sequence of SQL commands or operations that would trigger this issue
- Be precise -- don't just say "under concurrent access" or "with certain inputs"
- Describe the exact interleaving for race conditions, the exact input values for logic errors

### 4. Write a Test Case (if possible)

- **Preferred**: SQL script -- standalone, runnable against the patched PostgreSQL install
- **Alternative**: TAP test -- only if the scenario requires server restart, crash recovery, replication, etc.
- Do NOT write C code or custom extensions unless the patch itself is about C/extension API
- If the issue genuinely cannot be tested (internal-only code path, requires specific timing), explain clearly WHY it can't be tested

If you need a running PostgreSQL server:
- Use the built install at: `postgres/builds/$ARGUMENTS/debug-meson/install/`
- Create a temp data directory: `DATADIR=$(mktemp -d /tmp/pg_validate_XXXXXX)`
- Initialize: `postgres/builds/$ARGUMENTS/debug-meson/install/bin/initdb -D $DATADIR`
- Start with Unix sockets ONLY: `postgres/builds/$ARGUMENTS/debug-meson/install/bin/pg_ctl start -D $DATADIR -o "-k $DATADIR -c listen_addresses=''"`
- Connect: `postgres/builds/$ARGUMENTS/debug-meson/install/bin/psql -h $DATADIR postgres`
- You may iterate: run your test, fix it, rerun until it works or you conclude it can't demonstrate the issue
- Clean up when done: `postgres/builds/$ARGUMENTS/debug-meson/install/bin/pg_ctl stop -D $DATADIR && rm -rf $DATADIR`

### 5. Render a Verdict

- **CONFIRMED** -- The finding is real and correctly assessed. Provide evidence.
- **CONFIRMED (severity changed to X)** -- The finding is real but should be reclassified.
- **DOWNGRADED to X** -- The finding has merit but is less severe than assessed.
- **WITHDRAWN** -- The finding is incorrect. The code is actually fine. Explain why.

## Output Format

Return your validation in this EXACT format:

### Validation: [finding title]

**Verdict:** [your verdict]
**Original Severity:** [from finding]
**Validated Severity:** [your assessment]

**Analysis:**
[Your detailed reasoning -- call stacks, code traces, scenario description]

**Test Case:**
- File: `[filename].sql` or `[filename].pl` (or "None -- [reason]")
- Result: [what happened when you ran it, or N/A if not runnable]

[If a test file was written, include its FULL content]

**Conclusion:**
[One paragraph summary of why this verdict]
```

---

### Step 3: Collect Results and Write Validated Findings

After all validation subagents complete:

1. Collect all validation results
2. For WITHDRAWN findings: note them briefly at the end (title + reason withdrawn)
3. For CONFIRMED and DOWNGRADED findings: update the finding with validation evidence
4. Save any test files to `postgres/findings/$ARGUMENTS/v{version}/tests/`
5. Classify post-worthiness for every surviving finding -- Confirmed, Downgraded, and the Trivial bucket that skipped validation (this is where low-value findings currently escape review); Withdrawn findings are not classified:
   - **POST** -- worth posting.
     The bar: would the reviewer post this to the mailing list?
   - **FYI** -- kept for the record, not recommended for posting.
   Defaults: TYPO -> POST; NITPICK -> FYI.
   Judge all other severities individually against the bar.

Write `postgres/findings/$ARGUMENTS/v{version}/03-review-validated.md`:

```markdown
# Validated Findings: $ARGUMENTS v{version}

## Validation Summary
- Findings validated: N
- Confirmed: N (unchanged: N, severity changed: N)
- Downgraded: N
- Withdrawn: N
- Trivial (skipped validation): N
- Recommended to post (POST): N
- FYI (not recommended): N

## Confirmed Findings

### Finding: [title]

**Severity:** [validated severity]
**Post-worthiness:** POST | FYI -- [one-line justification]
**Location:** `patch: path/to/file.c:123-145`

**Description:**
[Original description]

**Evidence:**
[Original + validation evidence]

**Validation:**
- Verdict: CONFIRMED
- [Detailed reasoning from validator]
- Test: `tests/[filename].sql` (if written)

**Suggested Fix:**
[Updated fix suggestion if the validation refined it]

[... repeat for each confirmed finding ...]

## Trivial Findings (validation skipped)

### Finding: [title]

**Severity:** [severity]
**Post-worthiness:** POST | FYI -- [one-line justification]
**Location:** `patch: path/to/file.c:123`

[Brief description]

[... repeat for each trivial finding ...]

## Downgraded Findings

[Same format but with explanation of why severity was reduced]

## Withdrawn Findings

[Brief list: title + one-line reason why it was withdrawn]
```

Commit: `git add postgres/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add validated findings"`

---

## Phase 5: Mailing List Cross-Reference -> `04-mailing-list-status.md`

1. Read `03-review-validated.md` (validated findings)
2. Read `discussion.txt` (the full mailing list thread) -- read the ENTIRE file
3. For each validated finding, determine its relationship to the mailing list discussion

Status categories:
- **NEW** -- Not mentioned or discussed on the mailing list.
  These are our unique contributions.
- **KNOWN** -- Mentioned or raised by someone on the mailing list.
- **FIXED** -- Was raised on the list and has been addressed in this version or confirmed fixed by the author.
- **UNDER_DISCUSSION** -- Actively being debated on the list, no resolution yet.

Write `postgres/findings/$ARGUMENTS/v{version}/04-mailing-list-status.md`:

```markdown
# Mailing List Cross-Reference: $ARGUMENTS v{version}

## Summary
- Total validated findings: N
- New (not on mailing list): N
- Known (already discussed): N
- Fixed: N
- Under discussion: N

## New Findings (not on mailing list)

These are findings from our review that have not been raised in the mailing list
discussion. These are the most valuable for mailing list feedback.

### Finding: [title]
**Severity:** X
**Location:** `patch: ...`
[Brief description -- enough to understand the issue without reading the full finding]

[... repeat ...]

## Known Issues (already discussed)

### Finding: [title]
**Severity:** X
**Raised by:** [who mentioned it on the list]
**List status:** [what happened -- acknowledged? disputed? partially addressed?]
[Brief description]

[... repeat ...]

## Fixed Issues

### Finding: [title]
**Originally raised by:** [who]
**How it was fixed:** [brief description]

[... repeat ...]

## Under Discussion

### Finding: [title]
**Severity:** X
**Participants:** [who is discussing it]
**Current state:** [summary of the debate]

[... repeat ...]
```

Commit: `git add postgres/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add mailing list cross-reference"`

---

## Phase 6: Final Summary -> `05-summary.md`

Read all previous phase outputs (00 through 04) and produce the final summary.

Write `postgres/findings/$ARGUMENTS/v{version}/05-summary.md`:

```markdown
# Review Summary: $ARGUMENTS v{version}

## Executive Summary

[2-3 paragraph overall assessment:
- What the patch does and its significance
- Overall code quality and readiness for commit
- Key concerns that should block or require attention
- Overall recommendation (ready, needs work, needs rethink)]

## Key Findings

[For COMPLEX patches, place the "### Design Concerns" subsection first, before "### New Findings".]

### New Findings (not yet discussed on mailing list)

These are our unique contributions -- prioritize these for mailing list feedback.

1. **[SEVERITY] [POST|FYI] [title]** -- [one-line description]
   Location: `patch: path/to/file.c:123`
   [2-3 sentence explanation of why this matters]

[... numbered list, ordered by severity ...]

### Known Issues (with our validation status)

[Findings already discussed on the mailing list, with our independent validation.
Note where our assessment agrees or disagrees with the list discussion.]

1. **[SEVERITY] [POST|FYI] [title]** -- raised by [who], our verdict: [CONFIRMED/DOWNGRADED/TRIVIAL]
   [1-2 sentence update]

### Design Concerns

[High-level design issues from 01-design-review.md, if any.
These are separate from code-level findings.]

## Test Cases Written

| File | Tests | Description |
|------|-------|-------------|
| `tests/[name].sql` | [what it tests] | [brief description] |

## Withdrawn Findings

[Findings that seemed like issues but were withdrawn after deep validation.
Brief list -- useful to show we were thorough but honest.]

## Recommendations for Mailing List Response

[Suggested points to raise on the mailing list, organized by importance.
Phrase as "our review identified" or "we found" -- these are the reviewer's findings.

Focus on:
1. NEW findings that the list hasn't seen yet
2. Independent confirmation or refutation of KNOWN issues
3. Design-level feedback if applicable
4. Test cases that demonstrate issues

Include ONLY findings classified POST. FYI findings must not appear here.]

## FYI Findings (not recommended for posting)

[One line per FYI finding: severity, title, location. Omit the section if empty.]

## Statistics
- Total initial findings: N
- Confirmed after validation: N
- Withdrawn after validation: N
- Trivial (skipped validation): N
- New (not on mailing list): N
- With test cases: N
- Recommended to post (POST): N
- FYI: N
```

Refresh the committed metadata so the title reflects the overview:
`../bin/findings-metadata --project postgres/project.yaml $ARGUMENTS`

Commit: `git add postgres/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add review summary -- review complete"`

---

## Completion

After all phases are done, print this summary:

```
Review complete for $ARGUMENTS v{version}

Output files:
  postgres/findings/$ARGUMENTS/v{version}/00-overview.md
  postgres/findings/$ARGUMENTS/v{version}/01-design-review.md
  postgres/findings/$ARGUMENTS/v{version}/02-code-review.md
  postgres/findings/$ARGUMENTS/v{version}/03-review-validated.md
  postgres/findings/$ARGUMENTS/v{version}/04-mailing-list-status.md
  postgres/findings/$ARGUMENTS/v{version}/05-summary.md
  postgres/findings/$ARGUMENTS/v{version}/tests/
  postgres/findings/$ARGUMENTS/v{version}/discussion.txt
  postgres/findings/$ARGUMENTS/v{version}/patches/

Start with 05-summary.md for the high-level view, or ask about any specific finding.
```
