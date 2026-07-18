# RSR-SPEC — Freeze source-rule specifications

**Verified.** The frozen spec is `notes/01-catalog.md`. This records what was run, what it showed, and
what changed while running it.

No product behavior changed. `LeanFmt/` is untouched — the correct footprint for a spec prompt, and
what `state/next.md` declared this to be ("Module: (docs only)"). The prompt's characterization tests
ship as a reproducible evidence experiment, following the `RRE-SPEC` precedent; the persistent
regression suite is `RSR-IMPL`'s to write alongside the implementations.

## The headline

**Two of the roadmap's four candidates cannot be source rules at all**, and the reason is one byte
fact: a source rule reads `raw.crlfToLf` and only that. BOM and mixed line endings do not survive
that into accepted source, so no rule can see them. The two that do survive — control bytes and bidi
marks — can only ever appear inside a string literal or comment, because bare occurrences are hard
parse errors. That acceptance fact is the token context the rules would otherwise need, so both are
honest byte scans with no context requirement.

```
                         bare in command stream      in string / comment
  UTF-8 BOM              reject (expected token)      accept (ordinary U+FEFF)
  isolated CR            reject (isolated CR)         n/a
  NUL / C0 / DEL         reject (expected token)      accept   <- FMT003
  bidi controls          reject (expected token)      accept   <- FMT004
  LF/CRLF intermixed     accept (crlfToLf -> LF)      —        <- invisible to a source rule
```

## Ships

- **FMT003** forbidden control byte; **FMT004** suspicious bidirectional control. Both
  `RuleImpl.source`, linear byte scans, report-only, default-enabled, category `security`, severity
  `warning`. Sets, ranges, and messages frozen in `notes/01-catalog.md` §3.

## Rejected (with cause)

- **UTF-8 BOM**: a bare BOM is a parse error, so it never reaches accepted source; the read boundary
  already rejects it (`ruff-01` §5). A rule would duplicate a rejection and could never fire.
- **Mixed line endings**: erased by `crlfToLf` before any rule runs; its only correction is canonical
  formatter output (forbidden as default lint noise). Endings live in `LineEndings`, never in facts.

## Commands run

- `lake env lean docs/projects/ruff-08-source-rules/evidence/01-acceptance.lean`
  → `evidence/01-acceptance.txt`. The acceptance table and byte facts of `notes/01-catalog.md` §1–2.
  Toolchain `leanprover/lean4:v4.32.0`.
- `LEAN_NUM_THREADS=1 lake build` — clean (no production change; confirms the tree still builds).
- `tests/boundary/run.sh` — passes; the source/dependency boundary is unchanged.
- `uv run .../check_stack.py <stack> --structural` and `write_next.py --check` — pass.
- `git diff --check` — clean.

## Remaining uncertainty

- **`ruff-01` precision gap (handed off, not blocking).** LF/CRLF-intermixed files are accepted by
  Lean but classified `.crlf` by `normalize`, so `denormalize` would rewrite bare-`\n` lines. Write
  safety is preserved by `ruff-01`'s round-trip invariant 4 (such files fail `validFor`; `fix`
  refuses them), so this is a prose imprecision in `ruff-01` §5, not a live defect. Recorded in
  `notes/01-catalog.md` §4 for `ruff-01` to own if it wants to.
- The exact `FMT003` set boundary (whether any additional format/space codepoints deserve inclusion)
  is frozen conservatively to C0-minus-TAB/LF plus DEL; `RSR-IMPL` may surface corpus evidence to
  widen it, which would reopen this note rather than drift silently.
