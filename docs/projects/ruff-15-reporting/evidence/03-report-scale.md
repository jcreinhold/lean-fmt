# Report renderer scale — RRF-FINAL

Owner: `ruff-15-reporting` prompt `03-acceptance` (claim `RRF-FINAL`).

The roadmap gate under test: *"benchmark large synthetic reports."* `evidence/02-renderer-cost.md`
measured the six renderers at 109 findings and the string-append pattern in isolation, and recorded
what neither covered — `Lean.Json.pretty`, SARIF's serializer, and the per-finding position lookups,
at scale. This is that measurement.

## Method

```sh
lake exe lean-fmt-tests report-bench
```

Driver: `LeanFmtTest.lean`, `reportBench` (section `ReportBench`). It builds a synthetic
`RunReport` of `n` findings spread over `⌈n/500⌉ FileReport`s, together with the matching
`PositionIndex`, and then times `formatReport` — the same function `runFileCommand` calls — once per
format. The fixture and the index are constructed and forced *before* any clock starts: both belong to
`LeanFmt.Application`, and billing them to a renderer would report the wrong thing.

The report is synthetic on purpose. The point is to vary report size across three orders of magnitude
while holding everything else fixed, which no real project offers — and the roadmap forbids running
full mathlib for development evidence in any case.

Fixture shape: every file's source is `n` copies of one 47-byte line, so finding `i` sits on line
`i + 1` at a computable offset. Codes cycle through four live rules (`FMT003`, `FMT004`, `FMT010`,
`FMT013`), which keeps SARIF's descriptor set and its `codes.contains` scan plural rather than
singular. Severities alternate; half the findings carry a fix, so the applicability branch is live.

- Commit: this stack's RRF-FINAL working tree
- Toolchain: `leanprover/lean4:v4.33.0-rc1`
- Machine: Darwin arm64

## Measured

| Findings | Files | `text` | `concise` | `json` | `github` | `sarif` | `junit` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 100 | 1 | 0.10 ms | 0.43 ms | 0.33 ms | 1.36 ms | 2.67 ms | 3.24 ms |
| 1,000 | 2 | 0.11 ms | 3.25 ms | 1.12 ms | 13.60 ms | 22.47 ms | 29.87 ms |
| 10,000 | 20 | 1.17 ms | 30.47 ms | 10.76 ms | 133.01 ms | 223.87 ms | 312.16 ms |
| 100,000 | 200 | 9.52 ms | 311.41 ms | 108.75 ms | 1521.54 ms | 2297.23 ms | 3231.36 ms |

Output bytes at 100,000 findings: `text` 7,824,734 · `concise` 6,946,400 · `json` 14,099,867 ·
`github` 16,981,400 · `sarif` 50,016,651 · `junit` 25,957,216.

Whole-process figures for the four sizes and all six formats together: **10.61 s wall**, peak RSS
**740 MiB**, 0 swap. The 8 GiB envelope was not approached.

## Result: linear, including `Lean.Json.pretty`

The ratio that matters is the last decade, where the timer resolution is no longer a factor. For a
10× larger report:

| Format | 10,000 → 100,000 |
| --- | --- |
| `text` | 8.1× |
| `concise` | 10.2× |
| `json` | 10.1× |
| `github` | 11.4× |
| `sarif` | 10.3× |
| `junit` | 10.4× |

Every format grows linearly with report size. SARIF's 10.3× is the figure `RRF-IMPL` could not
produce: `Lean.Json.pretty` over a 50 MB log is in that path, and it does not turn superlinear. The
`codes.contains` scan in `sarifReport` is O(results × distinct codes), and distinct codes is bounded by
the rule registry — four here, at most the registry's size ever — so it stays linear in results, which
these rows confirm rather than assume.

## What the rows say about where the time goes

`text` is the only format that does not resolve a position. At 100,000 findings it is **33× faster
than `concise` while emitting more bytes** (7.82 MB against 6.95 MB), so the gap is not serialization
volume. The cost of the four position-resolving formats is dominated by the two `PositionIndex`
lookups per finding, not by their serializers — `json` serializes 14 MB with no lookups in 109 ms,
while `concise` serializes 7 MB with 200,000 lookups in 311 ms.

This is worth recording because it is the opposite of the intuition `RRF-IMPL` was working from, where
SARIF's pretty-printer was the suspected scale risk. It is not: the index is.

## Calibration — what these numbers mean for a real run

The 109-finding warm run in `evidence/02-renderer-cost.md` took 0.51 s end to end, of which rendering
was under a millisecond. A 10,000-finding report — larger than this repository produces under
`--select all --preview` by two orders of magnitude — renders as JUnit in 312 ms. A 100,000-finding
report, which would mean a project roughly a thousand times this one's size, renders in 3.2 s.

Rendering is not a scale risk for any report a Lean project can produce. The stop rule "renderer
allocation must be bounded for project-scale reports" holds by measurement across three decades.

## What this does not establish

- It measures `formatReport` only. Building the `PositionIndex` — `Application`'s work, one forward
  pass per file with findings — is setup here and is not timed.
- The fixture's lines are uniform, so it does not probe a pathological source (one enormous line, or
  findings clustered at the end of a large file) where the index build, not the lookup, could differ.
  The index build is O(source bytes) by construction; nothing here contradicts that, and nothing here
  measures it either.
