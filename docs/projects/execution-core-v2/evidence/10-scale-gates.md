# Prompt 10 repository and design gates

Date: 2026-07-16

Prompt status: verified.

## Sequential gates

The following commands passed sequentially after the implementation and scale evidence were final:

```text
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
LEAN_NUM_THREADS=1 tests/compiler/run.sh
LEAN_NUM_THREADS=1 tests/check/run.sh
LEAN_NUM_THREADS=1 tests/modes/run.sh
LEAN_NUM_THREADS=1 tests/scale/run.sh
module first-command audit over every non-lakefile `.lean` outside `.lake`
check_stack.py docs/projects/execution-core-v2 --structural
write_next.py docs/projects/execution-core-v2 --check
git diff --check
```

The compiler suite's visible corrupt-artifact, invalid-header, and failed-elaboration errors were
expected negative cases. It restored each fixture and ended with `lean-fmt compiler facet tests
passed`. The remaining integration suites ended with their check, product-mode, and complete-
selection/module-evidence success sentinels. Stack structure reported 12 prompts, zero warnings, and
no errors; generated next state selected `11-serve`.

## Deep-module audit

The supplied audit script recognized Lean and requested a manual Lean-pattern audit. Inspection
against `references/lean4-patterns.md` found:

- The root `LeanFmt` module exports no application API; explicit `public` declarations are executable
  entry points only. All application declarations remain private-by-default module members.
- `Main` knows only `Cli.runCli`. `LeanFmt.Cli` knows intent, rendering, and exit mapping but no cache
  identity, Lake jobs, evidence strategy, setup, child lifecycle, validation sequence, or writes.
- `Application.execute` is the sole batch transaction. It owns cache preflight/early return, one
  shared module-evidence query, conditional official-facet access, exact fallback, validation,
  reporting, batch cache publication, and fix publication.
- `Project` owns complete selection, immutable snapshots, exact workspace/setup, and shared Lake
  evidence. Its `SourceTarget` and `Snapshot` constructors are private, so callers cannot fabricate
  partial project state or sequence setup construction.
- `ResultCache.open?` returns either a complete source/artifact/configuration epoch capability or no
  cache. Its storage map, index schema, load/write sequencing, and atomic publication are hidden.
- Registered facet descriptors do not escape `Application.officialArtifacts`; that operation batches
  jobs, forces no-build policy, recomputes authority, and returns semantic compiler payloads or ordered
  misses. No caller handles raw paths or reproduces the facet.
- No strategy trait, single-implementor abstraction, pass-through facade, temporal builder, public
  worker/jobs/pinning DTO, or duplicated private check facet exists. Search found none of the archived
  Rust execution names or `libleanshared` in active production.

The retained modules correspond to distinct policy-owning capabilities rather than one-field wrappers:
project snapshot/evidence, semantic cache, compiler analysis/artifacts, rules, checked edits,
application transaction, and CLI presentation.
