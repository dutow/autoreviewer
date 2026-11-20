<!-- project-specific:start -->
## pg_tde Review Context

pg_tde is a PostgreSQL extension implementing Transparent Data Encryption.
It inherits all PostgreSQL idioms (memory contexts, ereport/elog longjmp, palloc, StringInfo, List API, etc. -- review C code with those in mind).
Additionally:

1. **Storage manager (smgr) hooks**: pg_tde wraps the smgr layer to encrypt pages on write and decrypt on read.
   Check that the encrypted/decrypted path is symmetric and that page boundaries / LSNs are preserved.
2. **WAL encryption**: encrypted relations still WAL-log.
   Verify WAL records do not leak plaintext and that decryption keys are available during recovery.
3. **Key management**: principal keys + internal keys, key providers (file, Vault, KMIP).
   Check key lifecycle, rotation, and that keys are never written to disk or logs in plaintext.
4. **Extension lifecycle**: `CREATE EXTENSION`, SQL upgrade scripts (`pg_tde--X--Y.sql`), `.control` file.
   Verify upgrade paths and that new objects are created with correct ownership/permissions.
5. **pg_config-driven build (meson)**: the extension builds against a specific PostgreSQL install via `-Dpg_config`.
   Version-specific code paths (PG16/17/18) must compile against the targeted major.
6. **Catalog / shared memory**: any shared state for keys must be correctly sized, locked, and initialized in `_PG_init` / shmem hooks.
7. **Security-critical**: this is encryption code -- scrutinize IV/nonce reuse, key derivation, constant-time comparisons, and error messages that might leak secret material.

<!-- project-specific:end -->

---

## Severity Definitions

- **BUG** -- Almost certainly a bug.
  Wrong behavior, crash, data corruption.
- **LIKELY_BUG** -- Probably a bug but could be intentional in context not visible in the diff.
- **SUSPICIOUS** -- Looks wrong but might be correct; needs human review.
- **RISKY** -- Not wrong now but fragile, likely to cause bugs during future maintenance.
- **NITPICK** -- Correct observation but below the posting bar: style, comment wording, code organization, speculative coverage gaps.
  Kept for the record, not recommended for posting.
- **TYPO** -- User-visible typo in error messages, identifiers, option or setting names, documentation strings shown to users.

Every `**Severity:**` line in every output file must contain exactly one of these six values and nothing else -- no parenthetical qualifiers, no arrows, no invented labels (MINOR, LOW, etc.).
Reclassification notes belong in the finding body, never on the severity line.

---

## Citation Requirements

Every finding MUST include citations:

**When referring to the patch under review:**
- Format: `patch: path/to/file.c:123` or `patch: path/to/file.c:123-145` for ranges
- Quote the relevant code snippet

**When referring to existing project code (for comparison/examples):**
- Format: `src: path/to/file.c:123`
- Explain why this is the authoritative example to follow

**When referring to PR discussion:**
- Reference the comment author and approximate date
- Quote the relevant point

For each finding:
1. Cite the specific location in the patch
2. Explain why it is a problem
3. Cite existing project code or documentation demonstrating the correct approach
4. Suggest a specific fix

---

