# Testing lean-fmt

This doc covers the property and fuzz surfaces added for the conservative-edit contract. For the
performance surfaces (perf probe, benchmark, budgets) see [`performance.md`](performance.md); for the
corpus and golden suites see the corpus `README.md` under
`crates/lean-fmt-project/tests/fixtures/corpus/`.

Two layers, split by whether a real Lean parse is needed:

## CI-profile properties (no Lean worker)

`crates/lean-fmt-edit/tests/properties.rs` is a `proptest` suite over the worker-free core of the edit
engine — the byte↔line/column source map and the conflict-checked patch engine. It runs on stable Rust
in the default `cargo test` profile, needs no Lean sysroot, and shrinks any counterexample to a minimal
failing case persisted under `crates/lean-fmt-edit/proptest-regressions/`.

Properties, matching the roadmap's conservative-edit contract:

- **Source map round-trips.** Every character-boundary byte offset survives `line_column` → `byte_offset`.
- **Non-overlapping edits apply consistently.** A set of disjoint, non-stale edits applies to exactly the
  hand-spliced result and reports the right applied count.
- **Overlapping edits are rejected atomically.** Two edits over the same range are refused with
  `OverlappingEdits`, writing nothing.
- **Apply-then-diff is consistent.** The unified diff is empty exactly when the output equals the source.
- **Empty edit set is the identity.**

Run:

```sh
cargo test -p lean-fmt-edit --test properties
```

A longer pass just raises the case count (default 256):

```sh
PROPTEST_CASES=4096 cargo test -p lean-fmt-edit --test properties
```

## Worker-driven fuzz (needs a Lean sysroot)

`crates/lean-fmt-worker-child/tests/fuzz.rs` covers the two properties that need a real Lean parse —
**idempotence** and **parse preservation** — over the clean corpus files. It applies a deterministic
battery of mutations (trivia: trailing whitespace, blank lines, CRLF, blank padding; plus one structural
perturbation: body tab-indentation) and drives every mutant through a real installed worker. For each
mutant the worker *accepts*, it asserts the formatted output re-parses and re-formatting is a fixpoint.
Mutants the worker reports broken are skipped — the properties are stated only over parser-accepted
inputs — and a coverage guard (`accepted >= file count`) prevents a mutation family that always broke
from passing vacuously. It is `#[ignore]`d because it links no `libleanshared` itself but installs and
drives a real worker. Run:

```sh
LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
  cargo test -p lean-fmt-worker-child --test fuzz -- --ignored --nocapture
```

### Recorded run

- **2026-07-13, macOS, Lean v4.32.0-rc1 (debug):** `fuzz: 42 accepted mutant(s), 7 skipped
  (parse-disturbing)`, ~30 s wall. The seven skipped mutants are the `tab_indent_body` perturbations,
  which the worker now reports as a graceful parse `error`.

This fuzz found a real robustness defect on its first live run: the `tab_indent_body` mutation of
`comment-heavy/Documented.lean` put a tab in the **header region**, and `LeanFmt.Frontend.runParse`
extracted the import set (`Elab.headerToImports`) from the error-recovered header *before* checking the
header parse messages, reaching unreachable code in Lean's own `Elab.HeaderSyntax.imports` and aborting
the worker with `SIGABRT`. Fixed at root by moving the `headerMessages.hasErrors` guard ahead of any
header-syntax extraction, so a header parse error is reported as a clean `error` response (no imports)
rather than crashing the frontend. The fuzz's `tab_indent_body` mutants are the standing regression
guard: they now land on the graceful parse-reject path (the seven skips above).
