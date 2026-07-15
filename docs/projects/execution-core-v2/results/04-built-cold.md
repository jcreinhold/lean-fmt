# ECV2-BUILT-COLD result

Status: verified on 2026-07-15.

## Result

The only known generally exact ordinary-built fallback architecture is one fresh Lean frontend
process per file using the file's exact `ModuleSetup`. Process exit is the sound reclamation and
isolation boundary available in Lean 4.32. Same-process body reuse, superset environments, and unsafe
compacted-region release are rejected. The measured setup-free import lower bounds already cannot
approach the ten-minute mathlib goal; production must prefer exact semantic artifacts produced while
the compiler owns the file's environment.

No new public Lean lifecycle interface is justified. A future optimization belongs behind Lean's
existing source-plus-`ModuleSetup` frontend boundary and must preserve exact import ordering,
artifact identity, plugins, initializers, and body isolation.

## Measurements

All mathlib measurements used revision `783ccda4ee524f13cc5636237be0a1942bc04824`, Lean
`v4.32.0`, current ordinary build prerequisites, formatter cache cold, and `LEAN_NUM_THREADS=1`.
The prefix run used a 250 ms sampled 8 GiB RSS / normal-pressure / 256 MiB swap-growth termination
policy; this is a monitor, not an OS hard limit.

| Measurement | Files | Wall | Import phase | Sampled peak RSS | Pressure evidence | Swap delta |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| Setup-free fixed-sample lower bound | 62 | 49,197 ms | 43,229 ms | 2,842,992 KiB | 83% free at both endpoints | 0 KiB |
| Setup-free sorted-prefix lower bound | 2,031 | 1,675,503 ms | 1,508,758 ms | 6,797,232 KiB | sampled level 1 | −24,576 KiB |

Both timing rows deliberately omit Lake `ModuleSetup`; they are lower bounds on the exact fallback,
not differential-oracle runs. The prefix run had zero file failures and was intentionally sent
`SIGTERM` after the conclusion was decisive. Its 742.9 ms/file import mean has a naive linear
extrapolation of 108.9 minutes; profiled wall analogously extrapolates to 120.9 minutes. The sorted
prefix is not claimed representative, and it is not a complete benchmark. More directly, 2,031
files had already taken 27.9 minutes. The heaviest observed file,
`DownstreamTest/DownstreamTest.lean`, spent 4,294 ms loading and 8,098 ms finalizing its 10,406-module
environment.

The complete header census remained cheap and covered all 8,795 files: 8,357 distinct ordered source
headers, 8,090 singletons, and only 438 files repeating a prior source header. These are grouping
candidates, not an exact-context upper bound: setup fields can split groups and import overrides can
merge source headers.

## Correctness and isolation

- The setup-aware fresh oracle passes `Mathlib/Tactic.lean` and custom Aesop syntax in
  `Mathlib/Data/Finset/Attr.lean`.
- A fresh `B_Observe.lean` exits `0`; processing `A_Poison.lean` then `B_Observe.lean` in one runtime
  exits `1` with the intended process-global-state leak diagnostic.
- A setup-free incremental header image reproduced one top-level command-kind/range projection, but
  images are not produced by an ordinary build, cost the avoided import to create, and range from
  tens to hundreds of MiB per context. This is mechanism evidence, not a viable corpus cache.

## Commands

```sh
experiments/profile-run.sh --name ordinary-import-full-built \
  --project-root ~/Code/mathlib4 --build-state ordinary-built \
  --cache-state formatter-cache-cold --sources /tmp/ecv2-mathlib-full.txt -- \
  experiments/run-pure-lean-workload.sh import ~/Code/mathlib4 \
  /tmp/ecv2-mathlib-full.txt

(cd experiments/pure-lean-core &&
  LEAN_NUM_THREADS=1 lake env lean fixtures/B_Observe.lean)

(cd experiments/pure-lean-core &&
  LEAN_NUM_THREADS=1 lake exe pure-lean-core "$PWD" \
    "$PWD/fixtures/A_Poison.lean" "$PWD/fixtures/B_Observe.lean")
```

## Remaining uncertainty

The partial run does not establish the full-corpus maximum RSS, a hard memory bound, or complete wall
time, and makes no such claim. Those facts are unnecessary to reject this fallback for the ten-minute
target. A future two-session experiment must be monitored as one aggregate and cannot assume two
heavy files fit; the observed one-child-at-a-time sampled peak left only 1.52 GiB below the policy
threshold.
