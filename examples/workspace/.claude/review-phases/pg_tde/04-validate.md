Read 02-code-review.md in the output directory first.

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
You are validating a specific finding from a pg_tde patch review.
Working directory: the workspace root

## Project Context

[Include the full review-context section AND the full Severity Definitions section (including the exact-enum rule) from above]

## The Finding To Validate

[PASTE THE FULL FINDING TEXT HERE -- title, severity, location, description, evidence, suggested fix]

## Your Task

Deeply validate whether this finding is real and correctly assessed.

### 1. Read the Code

- Read the relevant patch code in `pg_tde/review/$ARGUMENTS/`
- Read the corresponding code in `master/` for comparison
- Read surrounding context: callers, callees, header files, related functions

### 2. Trace the Code Path

- Build a concrete call stack showing how the problematic code is reached
- Identify ALL callers of the affected function(s)
- Determine under what conditions the problematic path is taken

### 3. Construct a Concrete Scenario

- Describe a SPECIFIC sequence of commands or operations that would trigger this issue
- Be precise -- don't just say "under concurrent access" or "with certain inputs"
- Describe the exact interleaving for race conditions, the exact input values for logic errors

### 4. Write a Test Case (if possible)

<!-- project-specific:start -->
- **Preferred**: SQL script -- standalone, runnable against the patched PostgreSQL install
- **Alternative**: TAP test -- only if the scenario requires server restart, crash recovery, replication, etc.
- Do NOT write C code or custom extensions unless the patch itself is about C/extension API
<!-- project-specific:end -->
- If the issue genuinely cannot be tested (internal-only code path, requires specific timing), explain clearly WHY it can't be tested

<!-- project-specific:start -->
If you need a running PostgreSQL server:
- Determine the install dir `<PSP_INSTALL>` from the `psp_install` value in `pg_tde/builds/$ARGUMENTS/<config>/status.yaml`. For pg_tde the extension is `meson install`'d into the PSP install prefix, so the server binaries live under `<PSP_INSTALL>`, not a per-build pg_tde `install/` dir.
- pg_tde has already been installed into `<PSP_INSTALL>` by the build hook, so `CREATE EXTENSION pg_tde;` works in a fresh instance started from it.
- Create a temp data directory: `DATADIR=$(mktemp -d /tmp/pg_validate_XXXXXX)`
- Initialize: `<PSP_INSTALL>/bin/initdb -D $DATADIR`
- Start with Unix sockets ONLY: `<PSP_INSTALL>/bin/pg_ctl start -D $DATADIR -o "-k $DATADIR -c listen_addresses=''"`
- Connect: `<PSP_INSTALL>/bin/psql -h $DATADIR postgres`
- You may iterate: run your test, fix it, rerun until it works or you conclude it can't demonstrate the issue
- Clean up when done: `<PSP_INSTALL>/bin/pg_ctl stop -D $DATADIR && rm -rf $DATADIR`

<!-- project-specific:end -->

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
- File: `[filename].<ext>` matching the test-case kind above (or "None -- [reason]")
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
4. Save any test files to `pg_tde/findings/$ARGUMENTS/v{version}/tests/`
5. Classify post-worthiness for every surviving finding -- Confirmed, Downgraded, and the Trivial bucket that skipped validation (this is where low-value findings currently escape review); Withdrawn findings are not classified:
   - **POST** -- worth posting.
     The bar: would the reviewer post this to the PR discussion?
   - **FYI** -- kept for the record, not recommended for posting.
   Defaults: TYPO -> POST; NITPICK -> FYI.
   Judge all other severities individually against the bar.

Write `pg_tde/findings/$ARGUMENTS/v{version}/03-review-validated.md`:

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
- Test: `tests/[filename]` (if written)

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

Commit: `git add pg_tde/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add validated findings"`

---

