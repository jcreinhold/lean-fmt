# Plan: canonical import layout for the organizer (kan-proofs parity)

## Context

kan-proofs enforces its import header style with a standalone Python script
(`kan-proofs/scripts/lean/canonicalize_lean_imports.py`):

```
<copyright block, verbatim>
module
<public import block>
<import all block>
<import block>
<body, verbatim>
```

Each block is partitioned into `Lean…` / `Mathlib…` / other sub-blocks separated by a
single blank line, alphabetical within each sub-block; blocks separated by a single blank
line; trailing `-- comments` (e.g. `-- shake: keep`) ride with their import.

lean-fmt's organizer (`Imports.organize`, LeanFmt/Imports.lean) today only sorts within
existing blank-line/comment-delimited groups and never crosses them — it cannot produce
this layout. Goal: an opt-in **canonical** import layout in lean-fmt so kan-proofs can
retire the Python script and get the same bytes from `lean-fmt organize` (CLI + LSP).

Feasibility: `HeaderModel`/`ImportStmt` already capture everything needed (module name,
`public`/`all`/`meta` flags, statement and line ranges). The whole pipeline —
candidate computation, re-elaboration validation, atomic publish, verdict cache, LSP
code action — flows through three choke points (`Imports.organize`,
`Imports.organizeCandidate?`, `ExactRun.organizeSnapshot`), so one new layout function
plus a threaded config covers every entry path. No new module is needed.

## Approach

- New `[format]` key `import-layout = "grouped" | "canonical"` (default `grouped` —
  today's behavior, so this is strictly opt-in). Identity-bearing like every `[format]`
  key, folded into `FormatConfig.identityString`.
- New `[format]` key `import-groups = ["Lean", "Mathlib"]` (default matches the script):
  the ordered prefix list for sub-blocks within a bucket; everything else trails.
- `Imports.canonicalize`: pure `(HeaderModel, normalized, groups) → Option String`
  rebuild of the header region. `none` = refused (see safety rules).
- `Imports.organize` gains a layout parameter; `organizeCandidate?` reads the target's
  `FormatterConfig` so CLI batch, LSP code action, and `Cache.liveDigests?` agree.

### Canonical emission rules (script parity)

1. Buckets in order: `public import`, `public meta import`, `import all`, `import`,
   `meta import` — each meta variant immediately after its non-meta counterpart. Empty
   buckets omitted. Sub-block prefix grouping applies inside meta buckets too.
   (The Python script has no meta rule — its regex stops the header at a `meta import`
   line — so this ordering is lean-fmt's own, and is what lets kan-proofs' Tactic files
   canonicalize fully for the first time.)
2. Within a bucket: sub-blocks ordered by prefix group (`Lean`, `Mathlib`, then other) —
   contiguous, no blank lines between them (the script's tests pin this; its module docstring
   claiming blank-line-separated sub-blocks is wrong) — alphabetical by full module path
   within each sub-block.
3. Single blank line between non-empty modifier buckets.
4. Duplicates removed (same `sameImport` rule as FMT003/`organize`).
5. Trailing `-- comment` on an import line is captured and reattached after sorting.
6. Everything outside the import region (copyright block, `module`, `prelude`, body,
   blank line before body) is preserved verbatim.

### Safety rules (stricter than the script, because lean-fmt moves lines)

- A **standalone comment line** between imports ends the canonical region (script
  parity): imports after it are left untouched, still idempotent.
- A **block comment** (`/- … -/`) anywhere inside the import region ⇒ refuse (`none`);
  reordering around a possibly multi-line block comment can drop or dupe text.
- Any trailing line content after the statement that is not a `--` comment ⇒ refuse.
- Every published rewrite is still validated by re-elaboration (existing
  `organizeWorker`/`organizeSnapshot` discipline) — canonical layout inherits it.

## Files to modify

- `LeanFmt/Imports.lean` — `canonicalize`, layout enum, refactored `organize` /
  `organizeCandidate?` taking the layout + groups.
- `LeanFmt/Config.lean` — `ImportLayout` type, `import-layout` / `import-groups` keys,
  `FormatConfig.identityString`.
- `LeanFmt/Application.lean` — thread `target.config.format` into the candidate calls
  (`organize`, `organizeSnapshot`).
- `LeanFmt/Cache.lean` — `liveDigests?` passes each target's layout to
  `organizeCandidate?`.
- `docs/configuration.md` — document the two keys.
- `tests/Test/Unit/Imports.lean` — canonical layout unit tests (script's test suite
  ported: sub-block order, bucket separation, trailing comments, module line,
  idempotence, refusal cases).
- `tests/Test/Unit/Config.lean` — key parsing/validation tests.
- `tests/Suites/Imports.lean` + `tests/fixtures/imports/` — end-to-end CLI test with a
  canonical-layout config fixture.

## Reuse

- `Imports.parseHeaderModel`, `ImportStmt`, `HeaderModel` (LeanFmt/Imports.lean) — the
  entire header read side.
- `sameImport`, `slice`, `lineExtent` — dedup and byte-slicing helpers.
- `organizeWorker` validation + `publishAtomic` (LeanFmt/Application.lean) — unchanged;
  canonical candidates ride the same validate-then-write path.
- `FormatConfig` key plumbing (LeanFmt/Config.lean:533-557) — pattern for the new keys.

## Steps

- [x] Config: `ImportLayout` inductive, `import-layout` + `import-groups` [format] keys,
      identity string, provenance.
- [x] `Imports.canonicalize` + layout parameter on `organize`/`organizeCandidate?`.
- [x] Thread config through `Application.organize`, `organizeSnapshot`,
      `Cache.liveDigests?`.
- [x] Unit tests (imports + config).
- [x] CLI end-to-end fixture + suite test.
- [x] Docs: configuration.md.
- [x] `lake build`, `lake lint`, `lake test -- --suites imports` + unit tier.

## Verification

- Unit: port the Python script's unittest cases (sub-block order, bucket separation,
  trailing comment retention, no-trailing-newline, idempotence) plus refusal cases
  (block comment in region, non-comment trailing content).
- E2E: fixture with a `lean-fmt.toml` enabling canonical layout; `organize --check`
  reports `would-organize`, `organize` writes bytes equal to the script's output on the
  same input.
- `lake build && lake lint && lake test`.

## Decisions (user)

- **Opt-in surface:** config key only (`[format] import-layout`), no CLI flag — one
  spelling keeps CLI, LSP, and the verdict cache in agreement.
- **Sub-block prefixes:** configurable via `[format] import-groups`, default
  `#["Lean", "Mathlib"]` (exact script parity out of the box).
- **`meta import` placement:** meta variant immediately after its non-meta counterpart
  (`public import`, `public meta import`, `import all`, `import`, `meta import`).

## Resolved details
