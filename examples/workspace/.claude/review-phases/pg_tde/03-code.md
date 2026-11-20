Read 00-overview.md and 01-design-review.md in the output directory first; audits the design review asked for are done in this phase.

## Phase 3: Deep Code Review -> `02-code-review.md`

Perform a thorough, line-by-line review of the entire patch.
This is the most detailed phase.

Use subagents to:
- Find similar patterns in the project's codebase (in `master/`) to compare against
- Look up how similar problems are solved elsewhere in the code
- Verify coding conventions against existing examples
- Read header files and related source files for context on data structures and calling conventions

Review the patch against ALL of these criteria:

<!-- project-specific:start -->
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
<!-- project-specific:end -->

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

Write `pg_tde/findings/$ARGUMENTS/v{version}/02-code-review.md`:

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
[Use `src: path/to/file.c:123` for existing project code citations]

**Suggested Fix:**
[Specific code change or approach to fix the issue]

[... repeat for each finding ...]
```

Commit: `git add pg_tde/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add code review findings"`

---

