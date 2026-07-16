---
claim_id: ECV2-DESIGN
status: planned
depends_on: [ECV2-BUILT-COLD, ECV2-COMPILER-ARTIFACTS]
---

# Select and specify the native Lean architecture

## Task

Use the two measured execution paths to design the production modules at least twice and select the
smallest deep boundary that serves ordinary-built cold, formatter-integrated, and cache-warm runs
without leaking strategy into callers. This prompt selects interfaces and implements only enough
skeleton to prove ownership; it does not disguise an unmeasured extraction mechanism as production.

## Read

- Results of ECV2-BUILT-COLD and ECV2-COMPILER-ARTIFACTS.
- `LeanFmt/ArtifactStore.lean`, `LeanFmtArtifactExtract.lean`, the `leanFmtArtifact` facet, and the
  exact fresh-process fallback experiment.
- The Philosophy of Software Design chapters on deep modules, information hiding, pulling complexity
  downward, designing twice, and performance.

## Target

- Interface comments and signatures precede implementation.
- One private intent-to-report operation owns workspace discovery, artifact/cache decisions, exact
  fallback, resource enforcement, deterministic collection, and writes.
- Compare, with caller-knowledge and critical-path diagrams, at least:
  1. direct consumption wholly inside a Lake-owning operation;
  2. one bounded extractor invocation that consumes multiple exact module artifacts without
     retaining imported environments past the configured envelope; and
  3. isolated per-module extraction/fallback processes.
- Measure the smallest representative prototype needed to determine whether supported batch import
  can release each module environment. Record startup, per-module time, peak/terminal RSS, pressure,
  swap, and output equivalence. Do not repeat the frozen full sample when a targeted sequence can
  reject a retention hypothesis.
- The selected boundary fetches a facet and validates its descriptor/source snapshot in one private
  operation. No ordinary caller can construct or retain a `Lake.Artifact`, artifact path, cache key,
  import environment, extractor command, or fallback choice.
- Model the three semantic outcomes explicitly: trusted module result, exact fallback result, and
  infrastructure failure. Missing/stale/corrupt artifacts are ordinary fallback inputs rather than
  errors exposed by a cache layer.
- Compiler plugin, artifact store, and fallback analyzer expose capabilities, not lifecycle steps.
- The design note identifies any non-Lean component by the exact missing Lean capability or measured
  advantage; otherwise the system remains pure Lean.
- Record rejected alternatives and the information hidden by each selected module. Prefer a single
  Lake-owned operation over a facade that merely forwards to artifact/cache/import helpers.

## Stop

No public strategy flags, single-implementor traits/typeclasses, pass-through facades, temporal setup
protocols, caller-visible cache/import sequencing, accumulated/superset grammar, or unbounded batch
retention. If no supported bounded extraction path exists, record the precise Lean/Lake facility
that is missing and retain the exact process boundary rather than inventing an unsafe shim.

## Check

- Run the deep-module audit before and after the skeleton.
- Inspect every caller; common CLI code must not know import or artifact strategy.
- Differentially compare every prototyped consumption path with the same compiler-owned artifact.
- Run the targeted batch-retention profile under the 8 GiB/pressure/swap stop guard.
- `lake build`
- `lake exe lean-fmt-tests`
- `git diff --check`
