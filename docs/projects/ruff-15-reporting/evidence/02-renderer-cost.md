# Renderer cost — RRF-IMPL

Owner: `ruff-15-reporting` prompt `02-renderers` (claim `RRF-IMPL`).

The stop rule under test: *"Renderer allocation must be bounded for project-scale reports."*

## Method

The renderers are pure `RunReport → String`, so the way to isolate their cost is to hold the analysis
fixed and vary only the format. Every row below is the **same run on the same warm cache**, differing
only in `--output-format`. The difference between rows is the renderer and nothing else.

```sh
app=$(lake -q query lean-fmt --text)
for f in text concise github sarif junit; do
  /usr/bin/time -l "$app" check --select all --preview --output-format $f >/tmp/scale.$f 2>/tmp/scale.$f.time
done
```

- Commit: this stack's RRF-IMPL working tree
- Toolchain: `leanprover/lean4:v4.33.0-rc1`
- Machine: Darwin arm64
- Workload: the whole `lean-fmt` project, `--select all --preview` (every rule, semantic tier demanded)
- Profile: **cache-warm**. The preceding cold run is reported separately below.
- Report size: **109 files, 109 findings**

## Cache-warm, one row per format

| Format | Output bytes | Output lines | Wall (s) | Peak aggregate RSS (MiB) |
| --- | --- | --- | --- | --- |
| `text` | 16,050 | 180 | 0.51 | 674 |
| `concise` | 16,159 | 126 | 0.50 | 674 |
| `github` | 30,079 | 126 | 0.51 | 674 |
| `sarif` | 74,575 | 1,919 | 0.52 | 675 |
| `junit` | 64,022 | 631 | 0.51 | 675 |

**Result.** SARIF emits 4.6× the bytes of `text` for +0.01 s and +1 MiB of peak RSS. The five formats
are within 0.02 s and 1 MiB of one another. Rendering is not a measurable share of a run, and the
allocation tracks report size — 109 findings — rather than project size.

No memory pressure was observed and no swap was added; the envelope stop rules (8 GiB aggregate RSS,
abnormal pressure, 256 MiB new swap) were not approached by any renderer row.

## The cold analysis run, for contrast

The first run of this workload — cold cache, every rule, semantic tier — took **87.16 s** and peaked at
**4,758 MiB**. That is the analysis, not the renderer: the very next run, warm, took 0.51 s at 674 MiB
and produced the same report. It is recorded so the warm figures above are not mistaken for the cost of
the whole product, and it stays inside the 8 GiB envelope.

## The accumulation pattern is linear, not quadratic

109 findings is a real project-scale report for this repository, but it is not a large one, and the
per-format deltas above are small enough that a superlinear term would be invisible in them. The
plausible failure mode is specific and worth naming: every renderer accumulates its output with
`out := out ++ …` in a loop, and if `String.append` copied, a large report would cost O(bytes²).

Measured directly rather than assumed (`evidence/02-append-growth-probe.lean`, run with
`lake env lean --run`):

```
n=1000    bytes=69,890      ms=0
n=10000   bytes=708,890     ms=0
n=100000  bytes=7,188,890   ms=0
n=400000  bytes=29,088,890  ms=0
```

Total process wall time for all four, including elaboration: **0.62 s**. Four hundred thousand
appended finding lines producing 29 MB of output register **0 ms** on the millisecond timer, and the
time does not grow with the square of `n`. Lean's `String.append` extends a uniquely-referenced string
in place with amortized growth, so the pattern is linear and the stop rule holds by measurement rather
than by hope.

## What this still does not establish

This probe measures the *accumulation*, not the whole renderer: it does not exercise `Lean.Json.pretty`
(SARIF's serializer, which the probe does not touch) or the per-finding position lookups. The roadmap
assigns "benchmark large synthetic reports" to **RRF-FINAL**, and that remains owed — a synthetic
report one to two orders of magnitude larger than 109 findings, rendered through all six formats
end to end, with SARIF's pretty-printer in the path.
