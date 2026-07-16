# Prompt 09 product-mode gates

Date: 2026-07-15

Prompt status: verified.

## Major step 1: checked patches

| Gate | Result |
| --- | --- |
| `LEAN_NUM_THREADS=1 lake build LeanFmt.Edit lean-fmt-tests` | pass; 18 jobs |
| `LEAN_NUM_THREADS=1 lake exe lean-fmt-tests` | pass |
| Range checks | out-of-bounds replacement rejected |
| UTF-8 checks | interior byte position of `α` rejected |
| Conflict checks | overlapping replacements and competing insertions rejected |
| Determinism | reversed adjacent input edits produce the same `AB` output |
| Reversibility property | every ordered pair of five UTF-8 boundaries × three replacements round-trips |

The focused suite also applies the real FMT001/FMT002 output to multibyte source and verifies exact
source-digest matching. No filesystem publication behavior is claimed by this step.

## Major step 2: product modes

`LEAN_NUM_THREADS=1 tests/modes/run.sh` passed this matrix:

| Contract | Evidence |
| --- | --- |
| Preview write safety | check/format/diff preserved source digest, nanosecond mtime, and mode |
| Stable output | golden full-source JSON and unified text diff; repeatable compiler reports |
| Semantic-source equality | artifact, exact fallback, and result-cache hit format reports were byte-identical |
| Cache projection | a cached canonical result was reprojected under per-file ignore with analyzer forced false |
| Configuration | include filtering, config ignore, CLI select precedence, per-file ignore, unknown-key failure |
| Statistics | JSON stdout remained valid; statistics appeared only on stderr |
| Validation rejection | valid broken-envelope response rejected the candidate; zero writes |
| Stale source | a before-write mutation was detected; formatter temporary output was not published |
| Safe fix | exact `--check-elab` validation, one atomic write, permission preserved, second run no-op |
| Rules | stable FMT001/FMT002 registry with category and fix metadata |
| Compiler setup | two byte-identical guidance reports; exact plugin/facet identifiers |
| Downstream integration | independent local Lake package loaded `@lean_fmt/LeanFmtCompilerPlugin:shared` and built `+Downstream:leanFmtArtifact` |
| Compiler status | two byte-identical, sorted audits; sidecar/source metadata unchanged |
| Clean | only `.lean-fmt-cache` removed; absent cache succeeded; build sentinel survived |

The unit suite additionally covers every ordered pair of UTF-8 edit boundaries with three
replacements, overlap/competing-insertion rejection, and exact inverse reconstruction.

## Sequential repository gates

The following passed in order:

```text
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
LEAN_NUM_THREADS=1 tests/compiler/run.sh
LEAN_NUM_THREADS=1 tests/check/run.sh
LEAN_NUM_THREADS=1 tests/modes/run.sh
module first-command audit over every non-lakefile `.lean`
check_stack.py docs/projects/execution-core-v2 --structural
write_next.py docs/projects/execution-core-v2 --check
git diff --check
```

The compiler suite deliberately exercises corrupt sidecars/oleans and failed elaboration; its
expected intermediate errors were followed by `lean-fmt compiler facet tests passed`. Stack
structure reported 12 prompts, 0 warnings. No full mathlib run was performed: Prompt 10 owns sampled
scale evidence and late candidate acceptance.

## Deep-module audit

- `LeanFmt.Application` no longer contains output-format, statistics, or argument-parser state.
- `LeanFmt.Cli` contains no Lake workspace, cache key, analysis strategy, retry, or write sequencing.
- `LeanFmt.Config` hides TOML/glob/selector mechanics behind path inclusion and finding projection.
- `LeanFmt.Edit` exposes only a fully checked patch, never partially ordered edits.
- Only `Main.main` is declared `public`; package-private internals require `import all` and the root
  `LeanFmt` module remains empty.
- No jobs, pinning, unsafe-validation, worker lifecycle, trait facade, or pass-through strategy DTO
  was introduced.
