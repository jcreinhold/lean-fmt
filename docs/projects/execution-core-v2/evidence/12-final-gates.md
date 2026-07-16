# Prompt 12 final evidence

Date: 2026-07-16

Prompt status: verified.

## Final candidate identities

- Active implementation base: `f3018ce3ca87c2d8ab5a27f3850fa6f97d4905a4`; the final audit
  commit changes documentation and the repository-only boundary guard, not the compiled product.
- Executable SHA-256:
  `27f7554ed0e0667f520df6341a940ef7ab3efd4e504b89685863221e9b982b7f`.
- Lean: `leanprover/lean4:v4.32.0`, git hash
  `8c9756b28d64dab099da31a4c09229a9e6a2ef35`.
- Mathlib: `783ccda4ee524f13cc5636237be0a1942bc04824`.
- Full workload: 8,795 sorted non-`.lake` sources, manifest digest
  `a74d51b39a9c4fe01c7d06ccb2d60325c89784c0244d6ceea1a9a927e1173286`.
- Machine: `supermartingale.local`, Darwin 25.5.0 arm64.

## Refreshed complete mathlib acceptance

Prompt 11 changed active `Application` code, so the final executable received one new monitored cold
run and its immediate forced worker-free warm run. Raw records are ignored local evidence under
`experiments/results/` with these stable names:

| State | Profile | Wall | Peak RSS | Pressure | Swap delta | Coverage | Output digest |
| --- | --- | ---: | ---: | --- | ---: | --- | --- |
| Ordinary built, formatter cache cold | `final-cold-full-acceptance-20260716T060324Z` | 136.549 s | 1,316,240 KiB | normal, level 1 | −8,192 KiB | 8,795/8,795 | `4cc843aa…` |
| Formatter cache warm | `final-warm-full-acceptance-20260716T060600Z` | 23.012 s | 1,150,128 KiB | normal, level 1 | 0 KiB | 8,795/8,795 | `4cc843aa…` |

Both profiles exited 0 with no hard stop, missing source, broken file, infrastructure failure, crash,
or abort. Direct JSON inspection proved 8,795 unique bytewise-sorted paths in each report, and `cmp`
proved the reports byte-identical. The cold run published one 3,362,610-byte atomic index. System
free memory declined from 76% to 64% during the cold trial, explaining ordinary timing variance, but
product RSS stayed essentially equal to Prompt 10's earlier candidate and no resource gate moved.

The warm command set `LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1`,
`LEAN_FMT_DISABLE_ARTIFACT=1`, and `LEAN_FMT_TEST_ANALYZER=/usr/bin/false`. Success therefore proves
the all-hit branch reached none of those evidence/frontend paths. No formatter-integrated full build
was run: every enabled rule declares source input, so `RulePlan.requiresSyntax` is false and
`Application.execute` skips `officialArtifacts`; an integrated build follows the same measured
ordinary-module-evidence path. Focused compiler gates separately cover the future syntax-input facet
path and its invalidation/corruption behavior.

## Final sequential gates

The following ran sequentially against the final executable and passed:

```text
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
LEAN_NUM_THREADS=1 tests/compiler/run.sh
LEAN_NUM_THREADS=1 tests/check/run.sh
LEAN_NUM_THREADS=1 tests/modes/run.sh
LEAN_NUM_THREADS=1 tests/scale/run.sh
LEAN_NUM_THREADS=1 tests/service/run.sh
tests/boundary/run.sh
```

The compiler suite deliberately produced invalid-facet, corrupt-olean, and failed-elaboration errors,
restored their inputs, and ended with `lean-fmt compiler facet tests passed`. Check, modes, and scale
ended with their named success sentinels. The service processed 100 exact unsaved requests at
1,039,120 KiB peak aggregate RSS; parent median RSS decreased from 797,504 to 733,184 KiB. The final
boundary sentinel was `lean-fmt native module and dependency boundary passed`.

## Source, module, and dependency audit

`tests/boundary/run.sh` makes these findings persistent:

- every tracked non-lakefile `.lean` begins with `module`;
- no Rust/Cargo workspace, target/cache/build path, generated binary, legacy execution name, worker,
  jobs, or pinning option is tracked in active production;
- `LeanFmt.lean` defines and imports nothing, and `LeanFmt/` contains no explicit `public` declaration;
- the only active explicit-public declarations are the application, artifact-extractor, and test
  executable `main`s;
- `LeanFmt.CompilerPlugin` imports exactly `ArtifactModel` and `Rules`, and its Lake target excludes
  application, cache, project, service, CLI, edit, and semantic orchestration modules;
- the common caller chain is `Main → Cli → Service → Application`, while batch commands call the same
  application operation and service calls only the bracketed exact snapshot capability;
- the Lake package and product executable are both exactly `lean-fmt`.

Manual declaration inspection confirmed private constructors for `Project.SourceTarget`,
`Project.Snapshot`, `Patch`, `ResultCache`, and `ExactRun`. The deep-module audit script reported that
it has no automated Lean backend; the required manual audit against its Lean patterns found no
single-implementor trait, one-field wrapper, pass-through facade, public strategy DTO, temporal close
protocol, or duplicated parser/orchestrator.

## Clean tracked-source package

`git archive f3018ce` was extracted without `.git`, `.lake`, cache state, or untracked files. It
contained no Rust/Cargo source. With only the pinned installed toolchain, the archive passed:

```text
LEAN_NUM_THREADS=1 lake build
lean-fmt --help
lean-fmt check --root . --json --no-cache LeanFmt/Basic.lean
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
lean-fmt serve --root .  # health then shutdown NDJSON
```

The archive built executable digest `27f7554…`, identical to the accepted candidate. The focused
check returned exactly `LeanFmt/Basic.lean` with no broken/infrastructure result; service returned two
valid responses; no `.lean-fmt-cache` appeared. The first shell wrapper used zsh's read-only `status`
name after a successful build and was discarded; the corrected `check_status` wrapper passed. The
repository boundary guard intentionally requires Git metadata and is run in the checkout, not the
source archive.

## Documentation and stack

Fresh searches of README, AGENTS, roadmap, notes, and results found Rust/workers/pinning/superset
terms only in explicit historical rejection or prohibition records. Current usage names complete
source selection, source-versus-syntax evidence, exact fallback, aggregate cache, ordinary-built
versus formatter-cache state, final cold/warm numbers, and service bounds accurately. The structural
checker exits successfully with 12 prompts and no errors. It emits nine shape warnings because it
applies active-packet field checks to the generator's intentional `first_unresolved: none` completion
stub; `write_next.py --check` independently confirms that stub is exactly current. `git diff --check`
passes.

No completion uncertainty remains.
