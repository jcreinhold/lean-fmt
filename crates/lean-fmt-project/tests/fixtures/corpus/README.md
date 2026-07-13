# lean-fmt test corpus

A small, categorized corpus of Lean 4 source files used by the golden suite (`crates/lean-fmt-project/tests/corpus.rs`),
the benchmark harness (`crates/lean-fmt-project/benches/corpus.rs`), and the env-gated formatter idempotence test
(`crates/lean-fmt-worker-child/tests/corpus.rs`).

## Licensing and provenance

**Every file here is original, written for this repository.** Nothing is vendored from Mathlib or any other external
project, so there is no third-party licensing or vendoring question to resolve. The fixtures are covered by the same
dual `MIT OR Apache-2.0` license as the rest of lean-fmt (see `LICENSE-MIT` / `LICENSE-APACHE` at the repo root).

The "mathlib-style" category imitates Mathlib *idioms* (typeclasses, namespaces, `by` proofs), not Mathlib *content*:
those files import only `Init` and parse standalone.

## Categories

Each subdirectory is one category. Non-`broken` files are expected to parse cleanly; `broken` files are expected to fail
parsing and be reported, never formatted.

| Category | Disposition | What it stresses |
| --- | --- | --- |
| `small` | clean | tiny single-declaration files |
| `medium` | clean | a structure, a namespace, an inductive, a tactic proof |
| `large` | clean | many declarations in one file (declaration-count cost) |
| `custom-syntax` | clean | user `notation`, `infixl`, and a `macro` |
| `mathlib-style` | clean | a typeclass with instances and `by` proofs, Mathlib-idiom |
| `broken` | broken | files that do not parse (reported, never formatted) |
| `comment-heavy` | clean | module/decl docstrings, line and nested block comments |

## The baseline

`baseline.json` is the committed structural baseline the corpus produces: per-category file counts, byte totals, line
totals, and declared disposition, plus the whole-corpus totals. It is a pure function of the file contents — no timings,
no machine paths — so it is reproducible anywhere. `tests/corpus.rs` recomputes it and fails if the corpus drifts from
the committed baseline; regenerate with `LEAN_FMT_UPDATE_BASELINE=1 cargo test -p lean-fmt-project --test corpus`.
