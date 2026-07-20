---
kind: state
first_unresolved: 02-implementation
---

# Current state

Its external prerequisite stacks are `ruff-04-formatter-product`, `ruff-11d-format-in-place`, and
`ruff-13-config-discovery`; all three record `first_unresolved: none`, and their live code was re-read
for this freeze (`Cli.lean`, `Application.lean`, `Service.lean`, `Project.lean`, `Printer.lean`,
`Doc.lean`, `Comments.lean`). If live code contradicts a prerequisite result, reopen the owning
prerequisite rather than patching around it.

**RSF-SPEC is verified** (`results/01-contract.md`; freeze `notes/01-stream-range.md`; baseline
`evidence/01-stream-range-baseline.md`). CLI forms, filename requirements, position encoding, the
layout-unit lattice and its expansion rule, comment ownership at boundaries, diagnostics, exit codes,
and cache/write policy are frozen precisely enough for `RSF-IMPL`. Following the `*-SPEC` convention
(`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC), no production Lean interface, config key,
or CLI surface shipped; one characterization test did.

Key frozen decisions:

- `-` is a **file target**, accepted only as the sole target, and **`--stdin-filename PATH` is
  required** with it. This is stricter than `ruff format -` deliberately: since `ruff-13` the effective
  configuration is resolved from a file's location in the tree, so a buffer with no location would get
  built-in defaults and silently answer differently than the same bytes on disk. **stdin must not
  become a second configuration path.** The path need not exist — it is identity, never content — which
  is the one place the implementation cannot reuse `Project.snapshotTarget` (it reads the file). Every
  gate that operation applies still applies, including the `.lake` floor `ruff-13` closed.
- **Reflow stability is a property of `Doc.fits`, not of commands** — the load-bearing finding.
  `fits` walks the *tail* of the work list, so a group at the end of a unit can be rebroken by what
  follows it. Exactly one construct stops the walk: a `verbatim` holding a newline
  (`Doc.lean:174-176`). Measured at margin 10 (`evidence` §3): a newline-terminated unit survives a
  16-character tail; a space-terminated unit is rebroken by a **one-character** tail. So expansion is
  "the units the request intersects, **then keep extending while the last unit does not end in
  newline-bearing trivia**" — without the second clause, `def a := 1 def b := 2` lets a range rewrite
  bytes it reported as untouched. Pinned by a characterization test in `testDoc`.
- The **unit lattice** is header `[0, headerStop)`, each `CommandSpan.extent`, and the tail
  `[terminalStop, normalizedBytes)`. Command extents already tile `[headerStop, terminalStop)` gap-free
  (`structurallyValid` requires it), so the three kinds tile the file and every byte has exactly one
  unit. The actual range is the hull of the selected units and **may span lines the caller did not
  edit**.
- **Comment ownership at extent boundaries is trailing-greedy** (`RLC-SPEC`: `nonempty_leading=0`,
  `verdict=trailing-greedy`): a comment block written *above* a declaration is in the **earlier**
  command's extent. This is extent ownership, not the finer `Comments.partitions` attachment that
  `tests/layout/run.sh` reports as `own-line comments lead the next token`; both hold, and RSF-IMPL
  must not "reconcile" them by changing either.
- Positions are **normalized-source** (`raw.crlfToLf`) half-open byte ranges; the line/column entry
  form uses 1-based lines and 1-based **codepoint** columns, converted to bytes at the CLI boundary.
  UTF-16 belongs to `ruff-17-lsp`.
- Output is `prefix ++ rendered(units) ++ suffix`, denormalized to the received line-ending form. The
  only documented boundary whitespace is (a) `normalizeEof`, which applies **only when the selected
  units include the tail**, and (b) trivia inside the selected units. Full-range equivalence falls out.
- **stdin never writes source and never touches persistent cache entries** — unconditionally, not by
  defaulting `--no-cache`: a cache entry is keyed on a digest bound to a file on disk. It gets the
  service's envelope: one `withExactRun`, a fresh bounded child, the `--max-memory` limit.
- **`--range` requires `-`.** A deliberate narrowing (`notes` §7.4): the roadmap forbids reintroducing a
  file-target stdout escape hatch, and a partial in-place write would be a new write surface with new
  stale-check semantics and no named caller.

**Interface obligations RSF-IMPL inherits, named in the freeze rather than left to be invented**
(`notes` §8): populate the source map (`Tree.document` must wrap each unit in `.mark` — `Printer` emits
none today, so the map the roadmap says to *reuse* must first be *produced*); keep one render with two
accessors rather than a second printer path; add a filesystem-free `SourceTarget` constructor; and keep
range expansion below the CLI in `LeanFmt.Application`.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-contract | RSF-SPEC | verified | — |
| 02-implementation | RSF-IMPL | planned | RSF-SPEC |
| 03-acceptance | RSF-FINAL | planned | RSF-IMPL |

## Blockers and prerequisites

- No blocker recorded. Uncertainty carried into `RSF-IMPL` (`results/01-contract.md`): the unit
  lattice's byte-for-byte reconstruction has not been re-measured on the frozen sample for range
  purposes; how often the forward-extension clause fires is uncounted; `normalizeEof`-at-the-tail is a
  frozen decision with no current caller to characterize against.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
