# Prompt 08 semantic-cache gates

Date: 2026-07-16

## Correctness matrix

`LEAN_NUM_THREADS=1 lake exe lean-fmt-tests` and `LEAN_NUM_THREADS=1 tests/check/run.sh` passed:

| Gate | Result |
| --- | --- |
| Source, toolchain, environment, formatter/rules, configuration, validation, artifact schema | each changes the identity digest; fixture keys are pairwise distinct |
| Compiler artifact versus exact fallback | byte-identical entry bytes and reports |
| Real all-hit run | analyzer replaced by `/usr/bin/false`; 62/62 sample hits still succeed |
| Source bytes changed | miss |
| Trusted trace contents changed | new epoch and miss |
| Required trace removed | cache disabled and analysis attempted |
| Corrupt committed entry | miss; exact result repairs it |
| Stray partial temporary entry | ignored; committed entry remains a hit |
| `--no-cache` with an existing entry | no read; forced analyzer failure is observed |
| `--no-cache` with no cache directory | successful analysis creates no cache path |
| Source safety | fixture contents and nanosecond mtimes unchanged after the suite |
| Module system | every compiled source starts with `module` |

The compiler suite separately proves source, rule configuration, plugin binary, `.olean`, sidecar,
and Lake restoration invalidation at the build-artifact layer below this result cache.

## Frozen measurement context

- Binary SHA-256: `2094306bb665f7120db614f9611a1d080307a003c740c63a63adc1ec97335eac`.
- Recorded base revision: `f0e0e7f2aea7c858624f734b41869140632ced26`; the Prompt 08 implementation
  was uncommitted, so the binary digest—not that base revision—is the exact candidate identity.
- Mathlib revision: `783ccda4ee524f13cc5636237be0a1942bc04824`.
- Toolchain: `leanprover/lean4:v4.32.0`.
- Machine: `Darwin supermartingale.local 25.5.0`, arm64.
- Envelope: 8,388,608 KiB aggregate RSS, pressure level at most 1, swap growth at most 262,144 KiB.

## Complete mathlib epoch

The full manifest contained 8,795 non-`.lake` sources with digest
`a74d51b39a9c4fe01c7d06ccb2d60325c89784c0244d6ceea1a9a927e1173286`. The hidden
measurement command performs workspace evaluation and the same cache-capability construction used by
`check`, but no source analysis or cache lookup:

```sh
.lake/build/bin/lean-fmt __measure-cache-epoch ~/Code/mathlib4
```

| Wall | Workspace | Epoch | Peak RSS | Pressure | Swap delta | Result |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 11,992 ms | 494 ms | 11,302 ms | 1,033,824 KiB | 1 | 0 KiB | cache enabled |

This validates all 8,782 root-package `.olean`s and the dependency/search roots; it is an epoch
measurement, not a full check.

## Genuine 62-file population and hit

Workload: the frozen bytewise-uniform sample, 62 files, manifest digest
`1936bdb60e01c14fdc986a535ef9317d63775506708e35f4155a9c4c5c6eeeef`. Build state was
ordinary-built. Compiler artifacts were disabled so every cold result came from the exact frontend.

| Run | Wall | Workspace | Snapshot | Epoch | Lookup | Peak RSS | Pressure | Swap delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cache-cold population | 193,610 ms | 532 ms | 14 ms | 11,299 ms | 13 ms | 1,068,624 KiB | 1 | −49,152 KiB |
| 62/62 cache hit, analyzer disabled | 11,709 ms | 505 ms | 5 ms | 10,877 ms | 40 ms | 1,031,504 KiB | 1 | 0 KiB |

Both outputs have digest `079e0178552735de2fb9e798cac87c0173f349bab390bbb2a4f0a1dbc8f24ce4`
and compare byte-for-byte. The warm command set both `LEAN_FMT_DISABLE_ARTIFACT=1` and
`LEAN_FMT_TEST_ANALYZER=/usr/bin/false`; success therefore proves the result returned before either
semantic source ran. Exactly 62 committed cache entries existed.

No complete mathlib check was run. The measured full epoch leaves substantial room under the
30-second goal, but source selection and 8,795 real entry lookups remain Prompt 10 acceptance work.

## Repository gates

The following passed sequentially:

```sh
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
LEAN_NUM_THREADS=1 tests/compiler/run.sh
LEAN_NUM_THREADS=1 tests/check/run.sh
LEAN_NUM_THREADS=1 lake exe lean-fmt -- check --help
bash -n experiments/profile-run.sh
git diff --check
```
