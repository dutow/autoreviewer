---
description: "Lightweight triage review of a batch of PostgreSQL master commits"
---

# PostgreSQL Master Commit Review

You are triaging commits already on PostgreSQL's `master` branch.
They passed upstream review, build, and the test farm -- do NOT build or run the test suite unless a specific finding needs runtime proof.
Run without stopping for user input.

The range to review is: `$ARGUMENTS` (format `<from>..<to>`, exclusive of `<from>`, inclusive of `<to>`).

## Severity Definitions

- **BUG** -- Almost certainly a bug.
  Wrong behavior, crash, data corruption.
- **LIKELY_BUG** -- Probably a bug but could be intentional in context not visible in the diff.
- **SUSPICIOUS** -- Looks wrong but might be correct; needs human review.
- **RISKY** -- Not wrong now but fragile, likely to cause bugs during future maintenance.
- **TYPO** -- User-visible typo in error messages, SQL function names, GUC names, documentation strings shown to users.

## What to flag -- and what not to

**Flag (worth mailing-list feedback):**
- Logic errors -- code doesn't do what the commit claims
- Security issues -- injection, privilege checks, ACL enforcement
- Crashes, data corruption
- Race conditions, locking mistakes (lock type, ordering, scope)
- Significant memory leaks (NOT palloc'd memory cleaned by its context)
- User-facing typos: documentation, error messages, SQL-visible names (functions, GUCs, catalogs)

**Do NOT flag:**
- Typos in code comments or internal identifiers
- Style, naming, or cosmetic refactoring preferences
- Theoretical micro-optimizations
- Deliberate trade-offs the commit message already explains

When in doubt whether a SUSPICIOUS/RISKY observation is worth flagging for an already-committed change, prefer CLEAN.
The bar is: "would the reviewer send this to the mailing list?"

## Setup

1. Split `$ARGUMENTS` into `<from>` and `<to>`.
   If `$ARGUMENTS` is not exactly `<from>..<to>`, stop with an error.
   (`<from7>`/`<to7>` below = first 7 characters of each; `<sha12>` = first 12 of a commit's sha.)
   Verify both shas exist: `git -C postgres/master cat-file -e <sha>^{commit}` for each -- if either fails, stop with an error (the master checkout may be stale; the poller refreshes it each cycle).
2. List the commits, oldest first: `git -C postgres/master rev-list --reverse <from>..<to>`
   If empty: print `No commits in range <from>..<to>`, then stop.
3. Ledger dedup: if `postgres/commit-reviews.log` exists, skip any commit whose full sha already appears on a `CLEAN` line.
   Commits on `FLAGGED` lines are re-reviewed (their findings dir is rewritten in place).
   If a re-reviewed commit now comes out CLEAN, remove its stale findings dir with `git rm -r postgres/findings/c<sha12>/` and include the removal in the batch commit.

## PostgreSQL Review Context

Keep these idioms in mind to avoid false positives:

1. **Memory contexts (MemoryContext)**: `palloc()` allocates in the current context, freed when that context is destroyed.
   Don't flag "missing free" for palloc'd memory in transaction or statement contexts.
2. **ereport/elog with ERROR or higher**: these `longjmp()` out.
   Code after `ereport(ERROR, ...)` is unreachable; don't flag "missing return after error."
3. **PG_TRY/PG_CATCH**: exception handling via `setjmp/longjmp`.
   Cleanup goes in `PG_CATCH`/`PG_FINALLY`.
4. **Buffer pins and locks**: `LockBuffer()`, `ReleaseBuffer()`.
   Look for mismatches, but some code intentionally holds pins across operations.
5. **Critical sections**: between `START_CRIT_SECTION()`/`END_CRIT_SECTION()` any ERROR becomes PANIC; WAL logging happens inside.
6. **LWLock vs heavyweight locks**: different mechanisms, different semantics; only heavyweight locks have deadlock detection.
7. **Catalog updates**: follow `CatalogTupleInsert/Update/Delete` patterns.
8. **GUC**: new GUCs need correct types, bounds, contexts, flags.
9. **WAL**: data modifications must be WAL-logged; record contents must match page modifications.
10. **1-based indexing**: attribute numbers and parameter positions are 1-based; arrays are 0-based.
11. **StringInfo**: the string buffer convention (`initStringInfo`, `appendStringInfo`, ...).
12. **List API**: PostgreSQL's `List *`, `lappend()`, `foreach()`.
13. **ResourceOwner**: tracks buffer pins, catcache refs etc.; auto-released on transaction abort.

## Triage each commit

For each commit, oldest first:

1. `git -C postgres/master show <sha>` -- read the full diff and commit message.
2. Assess against the flag/ignore criteria.
   Most commits should come out CLEAN after this step -- that is the expected outcome, not a failure.
3. If something looks off, deep-dive before flagging: read the surrounding code in `postgres/master/`, trace callers and callees, check how similar code handles the same situation.
   Use subagents for parallel investigation of independent suspicions.
4. A finding must be validated before it is persisted: a concrete call path plus a concrete trigger scenario (exact SQL, exact interleaving, exact input values).
   If you cannot substantiate it, the commit is CLEAN.

### Runtime verification (only when a finding needs proof)

Build master (artifacts go to `postgres/builds/master/debug-meson/`):

```bash
bin/pg-build --project postgres/project.yaml master debug-meson
```

Then, if a running server is needed:

```bash
INSTALL=postgres/builds/master/debug-meson/install
DATADIR=$(mktemp -d /tmp/pg_commit_review_XXXXXX)
$INSTALL/bin/initdb -D $DATADIR
$INSTALL/bin/pg_ctl start -D $DATADIR -o "-k $DATADIR -c listen_addresses=''"
$INSTALL/bin/psql -h $DATADIR postgres
# ... iterate on the repro ...
$INSTALL/bin/pg_ctl stop -D $DATADIR && rm -rf $DATADIR
```

If the build fails, do not debug it -- persist the finding on static evidence and note in Validation that runtime verification was unavailable.
Always stop the server and remove `$DATADIR` before moving on, even if the repro fails.

## Output for each FLAGGED commit

Create `postgres/findings/c<sha12>/v1/` where `<sha12>` is the first 12 characters of the full sha (always `v1` -- commits are immutable; a re-run overwrites `v1` in place).

**`metadata.json`** (`<now>` = current UTC time, ISO 8601):

```json
{
  "project": "postgres",
  "topic": "c<sha12>",
  "version": 1,
  "title": "<commit subject line>",
  "source_url": "https://git.postgresql.org/cgit/postgresql.git/commit/?id=<full sha>",
  "reviewed_at": "<now>"
}
```

**`00-commit-review.md`**:

```markdown
# Commit Review: <sha12>

**Commit:** <full sha>
**Author:** <author name> -- <author date>
**Subject:** <commit subject>

## What The Commit Does
[Short description of the change and its intent]

## Findings

### Finding: [short descriptive title]

**Severity:** BUG | LIKELY_BUG | SUSPICIOUS | RISKY | TYPO
**Location:** `src: path/to/file.c:123-145`

**Description:**
[What the issue is, why it matters]

**Evidence:**
[Code snippets; `src: path:line` citations to related master code;
the validated call path and trigger scenario]

**Suggested Fix:**
[Specific change]

[... repeat per finding ...]

## Validation
[How each finding was validated: code trace, concrete scenario,
test run results if a repro was executed]
```

**`tests/`** -- repro scripts, if any were written (SQL preferred).

## Ledger

Append the commit's line to `postgres/commit-reviews.log` immediately after finishing each commit -- do not batch the writes at the end of the run (the ledger must survive a session dying mid-batch).
Skipped commits are already there.
Format:

```
<UTC ISO 8601> <full sha> CLEAN|FLAGGED <commit subject>
```

## Commit (only if anything was flagged or withdrawn)

```bash
git add postgres/findings/c<sha12-1>/ [postgres/findings/c<sha12-2>/ ...]
git commit -m "review(commits): flag <M> commit(s) from <from7>..<to7>"
```

If stale findings dirs were removed (re-reviewed FLAGGED commits now CLEAN), the `git rm` above already staged the removals; mention them in the message, e.g. `review(commits): flag <M>, withdraw <W> from <from7>..<to7>`.

If nothing was flagged and nothing was removed, do NOT create a git commit -- the ledger is gitignored and is the only trace of a clean batch.

## Final output

Print exactly this shape:

```
Reviewed N commits (<from7>..<to7>): M flagged, K clean, S skipped (ledger), W withdrawn
FLAGGED:
  c<sha12> [SEVERITY] <one-line reason>
  ...
WITHDRAWN:
  c<sha12> <one-line reason the earlier finding no longer holds>
  ...
```

(omit zero counts from the summary line, and omit the FLAGGED/WITHDRAWN blocks when empty)
