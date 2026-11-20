Read 00-overview.md through 04-mailing-list-status.md in the output directory first.

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

Write `postgres/findings/$ARGUMENTS/v{version}/findings.json` with counts of the surviving findings in `03-review-validated.md` (Confirmed, Downgraded and Trivial; Withdrawn findings only go to `withdrawn`), by validated severity, and by post-worthiness:

```json
{
  "severity": {"BUG": 0, "LIKELY_BUG": 0, "SUSPICIOUS": 0, "RISKY": 0, "NITPICK": 0, "TYPO": 0},
  "post": 0,
  "fyi": 0,
  "withdrawn": 0
}
```

Every key must be present with an integer value, 0 when there is nothing to count.
The counts must match the Statistics section above.

Commit: `git add postgres/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add review summary -- review complete"`

---

