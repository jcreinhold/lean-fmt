# RSF-SPEC — results

**Claim:** the semantic fact boundary is characterized, the declared-spacing fact is designed (twice,
choice recorded), and `Tier.semantic` / the `v3→v4` schema bump / the demand-gating cost model are
specified precisely enough for RSF-IMPL. No tier or schema change ships in this prompt.

## What was done

- Read the two producers first-hand: the always-on `CompilerPlugin.produceArtifact`
  (`LeanFmt/CompilerPlugin.lean:26-39`, `getEnv` at 27) and the on-demand `analyzeExact`
  (`LeanFmt/Analysis.lean:53-87`, final command state at 77). Read the `v3` artifact
  (`LeanFmt/ArtifactModel.lean:103-127`) and the boundary test (`tests/boundary/run.sh`).
- Traced the declared-spacing mechanism through the pinned Lean 4.32.0 toolchain: `pushToken` and the
  symbol formatter (`Lean/PrettyPrinter/Formatter.lean:357-503`), the symbol parser's trim
  (`Lean/Parser/Basic.lean:1113-1116`), the token-table types (`Lean/Parser/Types.lean:37,39`), and
  the compiler's own doc for the whitespace pp-hint (`Init/Prelude.lean:5389`).
- Pinned the four fixture declarations (`Init/Notation.lean:284,293,295` + a corpus multi-atom
  notation); recorded them in `evidence/01-declared-spacing.txt`.
- Wrote the design-twice and the full boundary characterization in `notes/01-semantic-facts.md`.

## Commands / evidence locators

- `evidence/01-declared-spacing.txt` — the grepped source lines proving F1 (parser trims → token table
  holds `"+"`; formatter keeps untrimmed `" + "`; Prelude documents the pp-hint).
- Source locators are inline in the note (§1 F1–F4, §2 fixtures).
- `LEAN_NUM_THREADS=1 lake build` and `tests/boundary/run.sh`: run as gates on the *no-op* diff this
  spec produces (docs + evidence only; no `.lean` change) — see "Checks" below.

## Key findings (full argument in `notes/01-semantic-facts.md`)

1. **F1 — declared spacing is a formatter pp-hint, not a token-table entry.** The parser trims the
   symbol (`Basic.lean:1114`); only the formatter's untrimmed `sym` argument
   (`Formatter.lean:442-446`) carries the gap, which `pushToken` turns into a breakable `Format.line`
   (`Formatter.lean:412-414`). This **corrects the source-false "read from the token table" premise**
   in this stack's roadmap stop-rule and in the ruff-03 reflow note (fixed under this prompt, task 3).
   The fact is still captured, never guessed — the *source* is the formatter (the parser's inverse).
2. **F2 — no import-closure growth.** `import Lean` is already in the plugin closure via
   `ArtifactModel.lean:4`; the boundary test bans only lean-fmt's own volatile modules
   (`LeanFmt.Rules`/app), which churn traces. Reading Lean-core parser/formatter tables is legal.
3. **F3/F4 — two producers, one demand-gated.** The always-on plugin emits `semantic = none` (no probe
   cost, no trace churn in integrated builds); the on-demand `analyzeExact` emits `semantic = some`
   only when the run's required tier reaches `semantic`. `format` always does, so it drives a fresh
   `analyzeExact` and pays a recorded cost — honest demand-gating rather than an always-on tax.

## Chosen representation

**Design B — module-level per-kind ordered spacing template.** One entry per distinct
`SyntaxNodeKind` present, giving its atoms' declared gaps ordered by position. Chosen over Design A
(per-node inline gaps) on artifact size and cache locality, without losing the open set. The
multi-atom fixture (`«term_≃[_]_»`) rejects the per-*token* sub-variant: the same token declares
different gaps in different kinds, so the key must be (syntax-kind, atom position). An atom whose
declaration the probe cannot resolve degrades to conservative source bytes, never invented spacing.

## Specified for RSF-IMPL

- `Tier.semantic` added; lattice `source ≤ syntax ≤ semantic`; `requiredTier` fold unchanged; the
  formatter's demand is expressed as "`format` requires the semantic projection," outside the rule fold.
- `ModuleArtifact` gains `semantic : Option SemanticProjection := none`; `artifactSchema` →
  `lean-fmt.module-artifact.v4`; additive (the lossless `source` projection is unchanged); `v3` payloads
  miss, do not decode.
- Demand-gating: plugin `none`; `analyzeExact` `some` iff required tier reaches `semantic`; a `format`
  run rejects a `semantic = none` cache and re-analyzes. The semantic table is part of the digest, so a
  syntax-only cache and a semantic artifact are distinct identities.

## Remaining uncertainty

- Exact capture API (formatter-attribute entry point vs. a possible data-only atom store) — pinned in
  RSF-IMPL; formatter probe is the authoritative, comment-safe fallback.
- Per-kind probe cost — bounded by distinct-kind count; measured in RSF-FINAL, and confined to
  formatting runs by demand-gating.
- `unicodeSymbol` ASCII/unicode duals and non-symbol/ident atoms — recorded in `notes` §5; the latter
  degrade to source bytes, correct for RLF-NOTATION's scope.

## Checks

- This prompt ships **docs + evidence only** — no `.lean`, `lakefile`, or schema change — so the build
  and boundary gates run on an unchanged code tree (recorded below), and no import-closure growth is
  *proposed*; it is proved unnecessary (F2). RSF-IMPL owns the code change and its full gate set.
- Structural checker + `write_next.py --check` for `docs/projects/ruff-05b-semantic-facts`: pass.
- `git diff --check`: clean.
