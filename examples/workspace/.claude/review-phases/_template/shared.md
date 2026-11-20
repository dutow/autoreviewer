## Project Review Context

<!-- Fill in project-specific review idioms here: memory model, error/log
     conventions, locking, API conventions, common false-positive patterns.
     For PostgreSQL see .claude/commands/postgres/review-patch.md. -->

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

