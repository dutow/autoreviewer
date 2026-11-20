Read 00-overview.md and 03-review-validated.md in the output directory first.

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

