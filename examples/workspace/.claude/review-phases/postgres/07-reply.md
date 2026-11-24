Read 05-summary.md, 03-review-validated.md and 04-mailing-list-status.md in the output directory first.

## Phase 7: Mailing List Reply Draft -> `06-reply-draft.md`

Only run this phase if `findings.json` has `BUG` + `LIKELY_BUG` > 0 and at least one of those findings is classified POST.
Otherwise skip it: write no file and make no commit.

The draft is an email the reviewer can send to pgsql-hackers in their own name after editing.
It is never sent automatically.

1. Read `WRITING_STYLE.md` at the workspace root, if it exists, and follow it closely: voice, punctuation, mailing list conventions, and the "What NOT to do" list.
   Without it, write plainly and directly, like a terse pgsql-hackers review.
2. Read `05-summary.md` (Recommendations section), `03-review-validated.md` and `04-mailing-list-status.md`.
3. Read the end of `discussion.txt` and pick the message to reply to: normally the newest message that posted the reviewed patch version, or the newest message overall if the discussion moved on.

Content rules:
- Cover only POST findings, BUG and LIKELY_BUG first, in the order of `05-summary.md`.
  Lower severity POST findings may follow briefly at the end.
  Never include FYI or withdrawn findings.
- Skip findings that `04-mailing-list-status.md` marks FIXED.
  KNOWN or UNDER_DISCUSSION findings only get a short note, and only if our validation adds something (a reproducer, a confirmation, a disagreement).
- Write in first person singular ("I"), as the reviewer.
  Say in one sentence that the issues came from an automated review (e.g. "An automated review pointed out ..." or "A coding agent assisted review found ..."), but never name the agent or model, and never mention agents, phases, severity labels, POST/FYI, or the findings files.
- For each bug: what goes wrong, the concrete scenario or reproducer (short SQL / commands, inline, not as an attachment reference), the actual vs expected result, and the suggested fix if we have a confident one.
  Quote the relevant patch hunk (a few lines, as plain diff) when it makes the location clear.
  Do not overstate confidence: a LIKELY_BUG is written as a question or "I think", per the style guide.
- Number the points when there are 2 or more.
- Plain text email: no hard line wrapping (one paragraph per line), ASCII only, no markdown headers, bold or tables.
- Greeting "Hello" (no comma), no sign-off.
- Keep it short: the reproducer and the mechanism, not a narrative.

Write `$OUTDIR/06-reply-draft.md`:

```
# Draft reply: $ARGUMENTS v{version}

In-Reply-To: <message id> (<author>, <date>)
Subject: Re: <thread subject>

---

<email body>
```

Commit: `git add $OUTDIR/ && git commit -m "review($ARGUMENTS): add mailing list reply draft"`

---

