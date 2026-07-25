# 27 — Mathlib acceptance re-run and cross-binary byte stability

Prompt 27's condition: code changed since prompt 24 (`db5da78`), so the current-mathlib acceptance
runs once more. This file records that pass and a second, decisive experiment the first pass
forced: a byte-for-byte comparison between the binary prompt 24 measured and the current one.

- Command per chunk: `env LEAN_FMT_PROFILE_PHASES=1 experiments/run-check-workload.sh
  <binary> /Users/jcreinhold/Code/mathlib4 <chunk> format --check --json --no-cache
  --max-memory 6 --statistics` under `experiments/profile-run.sh`.
- Corpus: `experiments/workloads/mathlib-v4.33.0-rc1-audit.txt` (264 paths, 12,810,929 B),
  `split -l 44` into six consecutive chunks.
- Machine: arm64 macOS, 24 GiB; memory pressure 1 throughout; every run `hard_stop=none`,
  first attempt, zero guard interventions; mathlib HEAD `3de5ed81…` before and after (preview
  writes nothing).
- Aggregation: `experiments/aggregate-audit-digest.py` (committed with this file) — sha256 over
  every accepted candidate's `formatted` bytes, concatenated in frozen-manifest order.

## HEAD binary (`db5da78`)

| chunk | wall (s) | peak RSS (MiB) | exit |
| --- | --- | --- | --- |
| aa | 361.1 | 6,140 | 2 |
| ab | 250.6 | 4,388 | 1 |
| ac | 160.6 | 4,103 | 1 |
| ad | 254.0 | 4,572 | 1 |
| ae | 135.9 | 3,911 | 1 |
| af | 172.4 | 6,221 | 2 |

Counts: **would-format 241, clean 8, infrastructure-failure 15** — identical to 24's confirmation
pass, including the same fifteen refused paths (12 envelope exhaustions at 6.00–6.06 GiB against
6, plus the three correct/upstream refusals: `MathlibTest/Linter/LongFile.lean`,
`MathlibTest/FindDeprecations.lean`, `MathlibTest/Tactic/SolveByElim/DummyLabelAttr.lean`).
Route counters on every chunk: `official_artifact_miss=44 = targets` (mathlib is not integrated;
the `officialArtifacts` pre-filter changes nothing observable there), `active_children=1` × 264.

Candidates: 241 files, 2,232,257 bytes. Digest:
`c4a046dd431fbafe0e01024f82c048b36d85fb2d428f9446ddce566fbda2d03a`.

## Prompt-24 binary, rebuilt at `3bfeafe`

`git worktree add` at `3bfeafe`, `lake build`: the resulting binary's sha256 begins
`742f0ce0288ec363` — **identical to the binary digest 24 recorded**, so this is the same program
24 measured, not an approximation. Same corpus, same command, same machine:

| chunk | wall (s) | peak RSS (MiB) |
| --- | --- | --- |
| aa | 354.5 | 6,118 |
| ab | 213.9 | 4,370 |
| ac | 146.6 | 4,078 |
| ad | 232.8 | 4,557 |
| ae | 128.4 | 4,006 |
| af | 164.5 | 6,156 |

Counts: **would-format 241, clean 8, infrastructure-failure 15** — same files, same statuses.
Candidates: 241 files, 2,232,257 bytes. Digest:
`c4a046dd431fbafe0e01024f82c048b36d85fb2d428f9446ddce566fbda2d03a` — **identical to HEAD's**.

## Settling the digest disagreement

24's evidence records digest `f181a6e4…dc57ad` over the same 241 candidates and the same
2,232,257 bytes, and its aggregation script did not survive. Two binaries — 24's exact binary and
the current one — now agree on `c4a046dd…` under a committed aggregator. Equal candidate count and
equal byte total rule out any content or framing difference; only concatenation order can produce
24's value, and no tested order (manifest, reverse, report, content-sorted) reproduces it. The
settlement, per "if two records disagree, write down the disagreement": **candidate bytes are
byte-stable from `3bfeafe` through `db5da78`; 24's printed digest was computed by a lost
aggregation convention and is superseded by `c4a046dd…`, which is reproducible from
`experiments/aggregate-audit-digest.py` and the committed chunk outputs.**

## Reading

The R1 repair changed nothing on this corpus that it was not measured to change in 26: the twelve
heavy modules still refuse (their demand is beyond the envelope at both bounds), and every other
file's canonical bytes are unchanged. The repair's observable effect — *how* an over-envelope file
fails (child's own attributed memory exception vs parent's kill) — does not appear in aggregate
counts; both are `infrastructure-failure`.
