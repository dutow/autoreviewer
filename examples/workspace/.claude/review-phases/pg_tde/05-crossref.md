Read 00-overview.md and 03-review-validated.md in the output directory first.

## Phase 5: PR Discussion Cross-Reference -> `04-pr-discussion-status.md`

1. Read `03-review-validated.md` (validated findings)
2. Read `discussion.txt` (the full PR discussion) -- read the ENTIRE file
3. For each validated finding, determine its relationship to the PR discussion

Status categories:
- **NEW** -- Not mentioned or discussed in the PR discussion.
  These are our unique contributions.
- **KNOWN** -- Mentioned or raised by someone in the PR discussion.
- **FIXED** -- Was raised in the PR discussion and has been addressed in this version or confirmed fixed by the author.
- **UNDER_DISCUSSION** -- Actively being debated in the PR discussion, no resolution yet.

Write `pg_tde/findings/$ARGUMENTS/v{version}/04-pr-discussion-status.md`:

```markdown
# PR Discussion Cross-Reference: $ARGUMENTS v{version}

## Summary
- Total validated findings: N
- New (not in PR discussion): N
- Known (already discussed): N
- Fixed: N
- Under discussion: N

## New Findings (not in PR discussion)

These are findings from our review that have not been raised in the PR
discussion. These are the most valuable for PR feedback.

### Finding: [title]
**Severity:** X
**Location:** `patch: ...`
[Brief description -- enough to understand the issue without reading the full finding]

[... repeat ...]

## Known Issues (already discussed)

### Finding: [title]
**Severity:** X
**Raised by:** [who mentioned it in the PR discussion]
**Discussion status:** [what happened -- acknowledged? disputed? partially addressed?]
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

Commit: `git add pg_tde/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add PR discussion cross-reference"`

---

