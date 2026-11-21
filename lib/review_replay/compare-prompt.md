Phase: compare

# Compare two reviews of the same patch version

Review A (replay): $REPLAY
Review B (reference): $REFERENCE

Both directories hold a finished review of the same patch version.
In each, read `05-summary.md` (section "Postable points") and `03-review-validated.md` (findings whose post-worthiness is POST or POST-MINOR).
Read other files in the directory only when a point is unclear without them.

The postable points of a review are its findings rated POST or POST-MINOR.
Match the postable points of A against those of B:

- matched: A and B raise the same underlying problem in the same code, even if wording, severity, evidence or proposed fix differ.
- only_reference: a postable point of B that A does not raise as postable. In the reason, say whether A has it at a lower level (FYI, withdrawn, nitpick) or not at all.
- only_replay: a postable point of A that B does not raise as postable, with the same note about B.

A point matches at most one point on the other side.
Do not judge which review is right; only whether they raise the same points.

Write $JSON:

{"matched": [{"replay": "<A point title>", "reference": "<B point title>", "reason": "<one line>"}],
 "only_reference": [{"point": "<B point title>", "level": "POST|POST-MINOR", "reason": "<one line>"}],
 "only_replay": [{"point": "<A point title>", "level": "POST|POST-MINOR", "reason": "<one line>"}]}

Write $MD: the three lists with the one-line reasons, then two or three sentences on whether A misses anything a reader of B would care about.
Do not modify or commit any other file.
