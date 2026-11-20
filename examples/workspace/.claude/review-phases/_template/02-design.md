Read 00-overview.md in the output directory first (complexity class, idea status, previous version notes).

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

Write `<PROJECT>/findings/$ARGUMENTS/v{version}/01-design-review.md`:

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

Commit: `git add <PROJECT>/findings/$ARGUMENTS/ && git commit -m "review($ARGUMENTS): add design review"`

---

