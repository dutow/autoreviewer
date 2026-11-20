## PostgreSQL Review Context

When reviewing PostgreSQL code, keep these idioms in mind to avoid false positives:

1. **Memory contexts (MemoryContext)**: PostgreSQL uses hierarchical memory contexts.
   `palloc()` allocates in the current context, freed when that context is destroyed.
   Don't flag "missing free" for palloc'd memory in transaction or statement contexts -- it's freed automatically.

2. **ereport/elog with ERROR or higher**: These `longjmp()` out of the current execution.
   Code after `ereport(ERROR, ...)` is unreachable.
   Don't flag "missing return after error."

3. **PG_TRY/PG_CATCH**: Exception handling via `setjmp/longjmp`.
   Resource cleanup goes in `PG_CATCH` or `PG_FINALLY` blocks.

4. **Buffer pins and locks**: `LockBuffer()`, `ReleaseBuffer()`.
   The pin/lock protocol is critical -- look for mismatches but understand some code intentionally holds pins across operations.

5. **Critical sections**: `START_CRIT_SECTION()` / `END_CRIT_SECTION()`.
   Between these, any ERROR becomes PANIC.
   WAL logging happens inside critical sections.

6. **LWLock vs heavyweight locks**: LWLocks are lightweight, short-duration.
   Regular (heavyweight) locks support deadlock detection.
   Different mechanisms with different semantics.

7. **Catalog update patterns**: System catalog changes follow specific patterns with `CatalogTupleInsert` / `CatalogTupleUpdate` / `CatalogTupleDelete`.

8. **GUC (Grand Unified Configuration)**: Configuration variables.
   New GUCs need correct types, bounds, contexts, and flags.

9. **WAL (Write-Ahead Logging)**: Data modifications must be WAL-logged for crash recovery.
   WAL record contents must match actual page modifications.

10. **1-based indexing**: PostgreSQL uses 1-based for attribute numbers, parameter positions.
    Arrays are 0-based.
    Mixing these up is a common bug source.

11. **StringInfo**: String buffer API -- `initStringInfo`, `appendStringInfo`, `appendStringInfoChar`.
    Don't flag manual string handling when StringInfo is the convention.

12. **List API**: PostgreSQL's linked list implementation using `List *`, `lappend()`, `foreach()`.
    Not a C standard library list.

13. **ResourceOwner**: Tracks resources (buffer pins, catcache refs, etc.) owned by a transaction or subtransaction.
    Resources are auto-released on transaction abort.

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

