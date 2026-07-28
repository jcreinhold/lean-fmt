# Comment-transparent layout, pinned comments, and a `[format]` style surface

## Context

A `format` run on kan-proofs (1432 files, v0.1.5) mangled import headers. The concrete case (`UniversalSeries.lean`):

```lean
-- in:
public import Mathlib.Analysis.Complex.UpperHalfPlane.Exp -- shake: keep (required by shake-safe artifact evidence: Mathlib.Analysis.Complex.UpperHalfPlane.Exp)

-- out:
public
import
Mathlib.Analysis.Complex.UpperHalfPlane.Exp -- shake: keep (required by shake-safe artifact evidence: Mathlib.Analysis.Complex.UpperHalfPlane.Exp)
```

The line is 119 characters **only because of the trailing comment**. The code
(`public import Mathlib.Analysis.Complex.UpperHalfPlane.Exp`) is 58 chars and fits comfortably. Splitting the code gains
nothing — the comment still overflows on the last fragment — and it detaches tooling directives (`shake: keep` tells
shake to retain the import) from the line they annotate.

Reproduced in-repo: any trailing comment that pushes an import line past 100 chars splits `public` / `import` / path; a
short comment leaves the line intact.

The user asked for two things:

1. Fix the mangling, and make inline comments containing configurable phrases (default: `shake: keep`) immovable.
2. Make the formatter's style configurable "like ruff", with concise, natural key names.

## Findings (probe-verified, this is the behavioral spec)

Architecture: Lean's **registered formatter is the grammar authority** — it produces the `Std.Format` doc, including
break structure. `NativeLayout` transforms that doc: aligns native leaves with source terminals, replaces them with
original bytes, and applies an enumerated set of `BoundaryLayout` / `OffsideConstraint` corrections. Width decisions
happen in the core renderer, over leaves that **include comment bytes**.

- **B1 — comment-driven overflow (bug).** A trailing comment's bytes count toward the enclosing group's width. Past
  `line-width`, the group splits the code; the comment rides the last fragment. Confirmed: same import, short comment →
  flat; long comment → split.
- **B2 — `:=` body breaking (NOT a bug; it is the canonical style).** Every elaborable body breaks after `:=`:
  `def foo := Nat`, `:= true`, `:= ()`, `:= (true)`, `:= [1]`, `:= "hi"`, `:= 1`, `:= id 1` all become `def foo :=⏎  X`
  (`changed=1, written=1`). This matches Lean core's own `formatCategory` output at width 100, which breaks
  `def foo := bar` too. lean-fmt's only re-flattening correction is `:= by` (`collectUngroupedBodyStarts`). An
  already-broken body stays broken (idempotent). Earlier observations of "flat survives" were confounded: those files
  failed elaboration (unknown identifiers) and were returned untouched.
- A bare import under 100 chars never splits; overflow only enters via comments in practice (kan-proofs' longest import
  path is ~58 chars).

Policy consequence: B1 is a correctness fix — the comment must not influence layout. B2 is a *style* question — the fix
for users who want mathlib-style one-line bodies is a knob, and the `:= by` precedent proves the mechanism exists to
deliver it.

## Design

### Layout invariant (no knob — this is the bug fix)

**Comments are layout-transparent.** Break decisions are computed on the code alone. A trailing comment never changes
the layout of the code it trails; it reattaches to its owner's line after layout. Concretely:

- Code fits within `line-width` → construct stays flat, trailing comment reattaches and may overflow the margin. (Fixes
  B1.)
- Code alone overflows → construct breaks as today; the comment follows its owner token.

Seam: `ExactIsland.comment` already marks comment islands ("the only reason this flag exists" is exactly this layout
question); the boundary table (`boundaryStarts`, `NativeLayout.lean` ~2054–2077) and `unbreakableRunBoundaries` are the
correction mechanisms. Implementation chooses between excluding comment-island widths from the flatten decision or
emitting flat boundaries for single-line-source constructs; either must satisfy the invariant's test matrix below.

### Configuration surface

Ruff-style: a small set of opinionated, enum/list-valued keys in the existing `[format]` section (the section whose keys
change written bytes and therefore belong to cache identity). Two new keys:

```toml
[format]
line-width = 100                       # existing

# Inline comments containing any of these phrases are pinned: the formatter
# never moves them and never splits their line — even if the code alone
# overflows. Replaces the default when set; [] disables.
pinned-comments = ["shake: keep"]      # default shown

# Declaration body layout. "next-line" (default): the canonical style today —
# the body goes on its own line (`def foo :=` / `  1`). "same-line": keep the
# body on the `:=` line when the joined line fits `line-width`, joining
# already-broken bodies that fit; break as today when it does not.
declaration-body = "next-line"
```

Naming: `pinned-comments` — short, reads as the comments it affects, "pinned" is the intuitive verb (vs.
`pinned-comment-phrases`, `keep-comments` which suggests deletion, `comment-pins` which is noun-inverted).
`declaration-body` with `"next-line"` / `"same-line"` — both words name the observable outcome, not the mechanism.

Semantics:

- `pinned-comments` matches **line comments** (`--`) in trailing position. Matching is substring (so
  `shake: keep (reason)` matches `"shake: keep"`). Interior and block comments are out of scope.
- A pinned comment forces its owning construct flat regardless of width (the import must not split — the directive would
  dangle).
- `declaration-body = "same-line"` uses the existing `collectUngroupedBodyStarts` / `BoundaryLayout.flat` mechanism,
  generalized from `byTactic` bodies to any `declValSimple` body whose joined spelling fits. "Fits" is measured on code
  alone (per the transparency invariant).
- Both keys live in `[format]` → extend `FormatConfig.identityString` (the deliberate tripwire: "forgetting to extend it
  is the bug to prevent").
- Per-directory configs inherit and override wholesale, exactly like `line-width` (existing `orParent` merge machinery).

### Non-goals (state in docs)

Indent-width, quote-style, comment rewrapping, and any knob that requires overriding Lean core's *group structure*
wholesale rather than correcting boundaries. The grammar authority is the registered formatter; the `[format]` section
configures width, comment placement policy, and boundary corrections — nothing more is honestly deliverable today.

## Files to modify

- `LeanFmt/Config.lean` — `FormatConfig` fields + `identityString` (~line 56–63), `[format]` parser + validation
  (~465–479), `orParent` merge (~290), `config show` table (~626).
- `LeanFmt/Formatter/NativeLayout.lean` — comment-transparent width handling; pinned-comment force-flat;
  `declaration-body` consumption in `collectUngroupedBodyStarts` (~713).
- `LeanFmt/Analysis.lean`, `LeanFmt/Application.lean` (~677, ~1889), `LeanFmt/LanguageServer.lean` (~660, ~739–745) —
  plumb `FormatConfig` through where bare `lineWidth` goes today (`formatWidth?` call sites and `analyzer.format`).
- `docs/configuration.md` — both keys, the transparency invariant, the non-goals boundary.
- Tests: `tests/Test/Unit/Config.lean` (parse, default, replace, `[]`, identity change, `config show`, bad values);
  `tests/Suites/NativeLayout.lean`
  - fixtures under `tests/fixtures/native-layout/`; `tests/Suites/Discovery.lean`
  (per-directory override).

## Reuse

- `ExactIsland.comment` flag — `LeanFmt/Formatter/NativeLayout.lean` ~58.
- `collectUngroupedBodyStarts` (`:= by` force-flat) — ~708; the pattern to generalize for `declaration-body`.
- `unbreakableRunBoundaries` / `boundaryStarts` table — ~905, ~2054.
- `FormatConfig.identityString` and its tripwire comment — `Config.lean` ~63.
- `orParent` per-directory merge — `Config.lean` ~290.
- Config parse + `format.*` validation incl. section-misplacement error — `Config.lean` ~465–479.
- Suite harness patterns: `tests/Suites/NativeLayout.lean`, `tests/Suites/Discovery.lean`; fixture modules in
  `tests/fixtures/native-layout/` (built via lakefile `lean_lib`).

## Steps

- [ ] Config: add `pinned-comments : Array String` (default `#["shake: keep"]`)
      and `declaration-body` (enum, default `next-line`) to `FormatConfig`;
      parser, validation, `orParent` merge, `config show`, `identityString`.
- [ ] Plumb `FormatConfig` (not bare width) through `Analysis.format`,
      `Application` call sites, and the language server.
- [ ] B1 fix: comment-transparent break decisions in NativeLayout; trailing
      comment reattaches to owner line.
- [ ] Pinned comments: matching trailing comment forces its construct flat.
- [ ] `declaration-body = "same-line"`: generalize the ungrouped-body
      correction to joined-fits bodies; default path unchanged.
- [ ] Unit tests for config (defaults, replace, `[]`, identity string,
      `config show`, invalid values/section).
- [ ] Suite fixtures + cases: the import/comment matrix below, pinned vs
      unpinned, both `declaration-body` modes, idempotency, per-directory
      override.
- [ ] `docs/configuration.md`: keys, invariant, non-goals.
- [ ] `lake build && lake test && lake lint`; then a kan-proofs dry run on
      `UniversalSeries.lean` (header untouched, directive intact).

### Behavior matrix the fixtures must pin

| Input (code part ≤ 100 unless noted) | Today | After |
| --- | --- | --- |
| import + short trailing comment | flat | flat |
| import + long trailing comment (B1) | `public`⏎`import`⏎path | flat; comment overflows |
| import + long comment containing `shake: keep`, default config | split | flat (also via B1) |
| code > 100 + comment, no pin phrase | code splits, comment follows owner | unchanged |
| code > 100 + `shake: keep` comment | split (directive dangles) | flat (pinned) |
| `pinned-comments = []` + long `shake: keep` comment | — | B1 behavior only (code flat, comment overflows) |
| `def foo := 1`, default | `:=`⏎`1` | unchanged (`next-line`) |
| `def foo := 1`, `same-line`, joined fits | — | `def foo := 1` |
| `def foo := <body>`, `same-line`, joined > 100 | — | `:=`⏎`<body>` |
| `def foo :=\n  1`, `same-line`, joined fits | stays broken | joined |

## Verification

- `lake build && lake test && lake lint` in lean-fmt (all 32 suites, 127 linted files).
- kan-proofs spot check (dry run, no commit): `format` on
  `KanProofs/AlgebraicGeometry/EllipticCurve/TateCurve/Analytic/UniversalSeries.lean` leaves the `shake: keep` import on
  one line; `check` on a file with a long trailing comment reports no spurious change.
