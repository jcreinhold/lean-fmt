---
kind: state
first_unresolved: none
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
| 02-implementation | RSF-IMPL | verified | RSF-SPEC |
| 03-acceptance | RSF-FINAL | verified | RSF-IMPL |

**RSF-IMPL is verified** (`results/02-implementation.md`). Four pieces, in dependency order:

- `Tree.document` marks each layout unit and `Printer.formatWithMap` keeps the map; `format` is the
  text-only façade over it. One render, two accessors — not a second printer path. No output byte moved
  (`tests/printer/run.sh` round-trips the corpus byte for byte).
- `Application.sliceRange` — unit selection, the forward extension, the actual range, the splice.
  Nothing in it parses: a unit's emitted bytes are the bytes whole-file `format` produced for it, cut
  out of one whole-file render, so "never slice arbitrary bytes and parse them as an exact module" is
  unreachable rather than merely obeyed.
- `Project.unsavedTarget` / `loadWorkspaceOnly` — bytes and a path in, `SourceTarget` out, every
  `snapshotTarget` gate applied with the same messages naming the caller's own argument, and no
  filesystem read for content. A one-shot request does not pay to select the project.
- `Application.stream` plus the `-` / `--stdin-filename` / `--range` / `--range-lines` CLI surface. A
  separate operation from `execute`, because nearly every clause of a batch run is wrong for one
  unsaved buffer.

`tests/stream/run.sh` is the owning suite: 30 assertions over usage rejections, the identity gates
through the pipe, the write/cache prohibitions, all four modes, range expansion, full-range
equivalence, idempotence, UTF-8 columns, CRLF, and the JSON shape.

Amendments recorded in the result note: `--json` gained `formatted`/`diff` (a JSON consumer was getting
a source map for text it had not been given); `module?` resolves from the real path when the file
happens to exist, so a saved-but-edited buffer keeps its twin's exact Lake setup; `resolveLexically`
drops a `..` that would escape an absolute root, keeping `insideRoot` meaningful without a `realPath`
an unsaved path cannot have.

**The suite caught a false assertion on its first run, and the freeze had already called it.**
Re-running the *requested* range over the output is not a fixed point — formatting changes the unit's
length, so the same byte offsets name a different region and reach into the next command. Idempotence
holds in *output* coordinates: re-running the range the source map says the unit now occupies, which is
what an editor holding that map would send. The suite asserts that and documents the wrong version so
it is not reintroduced.

**Standing tax:** this repository is the printer's own corpus, so every production edit shifts
`ruff-03/evidence/01-projection-shape.txt` and the 33 prose figures `check-quoted-figures.py` holds to
it. Regenerate with `experiments/run-projection-shape.sh` and reconcile before `tests/printer/run.sh`,
or the suite fails on stale evidence rather than on anything this stack did.

**RSF-FINAL is verified** (`results/03-acceptance.md`). `tests/stream/run.sh` is 58 assertions; every
gap `RSF-IMPL` admitted is now fixtured, and two measurements exist that did not.

**The forward extension never fires on the frozen mathlib sample** — 2,854 layout units across 62
modules, 0 extending (`evidence/03-range-unit-census.txt`). Keep the clause anyway, and keep the
reasoning with it: the census says idiomatic Lean never leaves a unit ending mid-line, so the clause
costs nothing on real source *and* the only inputs that reach it are ones nobody writes and nobody
would think to test — exactly where dropping it would silently rewrite bytes the range reported as
untouched. It is now fixtured on real source (`def a := 1 def b := 2`, `8:18` → `8-30`) rather than on
a `Doc` probe alone, and the census instrument reads its count off the product's own
`Printer.formatWithMap`.

**A range costs what the whole buffer costs** (`evidence/03-stream-cost.txt`). One exact frontend run
over the whole buffer is the cost, and a range cannot avoid it without giving up exactness. Range
formatting is a precision feature, not a speed one — do not let the product or its documentation imply
otherwise. A stream request costs about what a cache-cleared single-file batch run costs.

Acceptance findings worth carrying: custom syntax declared *outside* a range is still in scope for the
command inside it; the `#exit` tail is a unit like any other and streams verbatim; `normalizeEof`
applies at the tail and only there; an empty range is a cursor selecting its containing unit; a range
inside a nested node widens to the enclosing command, because the lattice is command-granular by
construction; and the comment written *above* a declaration belongs to the **earlier** unit, so a range
over that declaration does not include it.

One freeze violation shipped in `RSF-IMPL` and was closed here: invalid UTF-8 on stdin emitted the Lean
runtime's `Tried to read from stream containing non UTF-8 data` rather than §6's
`stdin is not valid UTF-8`. `runStreamCommand` now decodes explicitly. A diagnostic the contract fixes
must not be an incidental runtime phrase.

## Blockers and prerequisites

- No blocker recorded; the stack is closed. Residual uncertainty, none of it load-bearing for this
  stack (`results/03-acceptance.md`): the census is one corpus at one width (80), and the driver takes
  the width as an argument so a narrower margin is re-run rather than reasoned about; it counts unit
  boundaries where the extension *could* fire, not requests, and no real request traffic exists until
  `ruff-17-lsp`; UTF-16 positions belong to `ruff-17-lsp` and have no code path here to test; the
  timings are single-machine, three runs, wall clock — the right shape for "a range is not cheaper" and
  too coarse for anything finer.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
