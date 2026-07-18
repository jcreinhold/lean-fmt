# RSR-FINAL — Benchmark and audit the source family

**Verified.** The two rules the catalog froze (`notes/01-catalog.md` §3) and `RSR-IMPL` shipped are now
covered end to end: a differential property/fuzz test pins the scans against an independent oracle, a
committed-byte fixture pins the whole CLI pipeline, and a growth-ratio microbenchmark pins the
linear-time and worker-free claims. No production module changed — the family was already implemented
and correct; this prompt is the audit that proves it, at the scale the earlier prompts deferred.

## What was built

- **`LeanFmtTest.testSourceSecurityProperties`** — a property/fuzz boundary test. It checks the live
  scans differentially against an *independent* oracle: `FMT003` by an explicit byte predicate,
  `FMT004` by explicit codepoint-list membership, neither reusing `Rules.lean`'s private
  `isForbiddenControl`/`isBidiControl`. The oracle sorts by the same `(start, stop, code)` key
  `findingOrder` uses, so the comparison pins the sort too. 120 inputs come from a deterministic LCG
  over a pool mixing forbidden controls, allowed controls (TAB/LF), every bidi width, safe ASCII, and
  safe 2/3/4-byte scalars, plus four hand-picked edges (empty, all-forbidden run, control adjacent to a
  mark, a mark at the final byte). Wired into the default `main` run.
- **`tests/check/Security.lean`** — the committed-byte corpus. A bidi mark (U+202E) inside a line
  comment and a NUL inside a string literal — the only two places a control or bidi byte reaches
  accepted source (`notes/01-catalog.md` §2). `tests/check/run.sh` runs `check --json --no-cache` over
  it and asserts both findings byte-exact in normalized coordinates, report-only, nothing withheld or
  written; the file is in that harness's `sources` set, so its closing `cmp` also proves `check` reads
  a control-byte file without altering a byte of it.
- **`LeanFmtTest.security-bench` + `tests/security/bench.sh`** — the linear-time claim as a persistent
  test. `security-bench` times `runSourceRules` on scan-clean inputs of doubling size (2.5 → 20 MB);
  `bench.sh` asserts growth *ratios*, not wall-clock budgets, because linear (8×) and quadratic (64×)
  differ by the size step and mean the same thing on any machine. It also asserts per-byte cost is flat
  across every adjacent doubling (a superlinear kink an end-to-end bound could miss) and reports the
  dense-input finding count to prove the scans fire at scale, worker-free.

## Commands

```bash
LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests   # clean (43 jobs)
lake exe lean-fmt-tests                                 # lean-fmt module-artifact tests passed
tests/check/run.sh                                      # lean-fmt check integration tests passed
tests/modes/run.sh                                      # lean-fmt product mode integration tests passed
tests/boundary/run.sh                                   # native module and dependency boundary passed
tests/security/bench.sh                                 # failures=0  (evidence/03-security-bench.txt)
/usr/bin/time -l lake exe lean-fmt-tests security-bench # peak RSS below
git diff --check                                        # no output
# from /Users/jcreinhold/Code/kan-proofs, pyyaml available:
uv run --with pyyaml python .claude/skills/lean-plan/scripts/check_stack.py <abs stack>   # OK, 0 errors
uv run --with pyyaml python .claude/skills/lean-plan/scripts/write_next.py --check <abs stack>
```

## Measurements

### Linearity (`evidence/03-security-bench.txt`)

Workload `LeanFmtTest.security-bench`; toolchain `leanprover/lean4:v4.32.0`; commit `ee7cd59`; Apple
M4 Pro (12 cpu, 24 GiB), Darwin 25.5.0 arm64. Cache/build state is irrelevant to the number: a
source-tier rule reads only the string it is handed, so there is no formatter cache, project setup, or
child process in the measurement. Single process throughout — **worker-free by construction**, not by
configuration. Peak RSS **159,514,624 B (~152 MiB)**, no swap, no abnormal pressure — the working set
is the 20 MB input and its doubling temporary, two orders under the 8 GiB envelope.

| input     | bytes      | ms    | ns/byte | findings |
| --------- | ---------- | ----- | ------- | -------- |
| clean-1x  | 2,555,904  | ~12.6 | ~5.0    | 0        |
| clean-2x  | 5,111,808  | ~25.0 | ~5.0    | 0        |
| clean-4x  | 10,223,616 | ~50.0 | ~5.0    | 0        |
| clean-8x  | 20,447,232 | ~99.0 | ~5.0    | 0        |

**7.8× over an 8× size step** (bound 20×), and per-byte cost is flat (~5 ns/byte) at every doubling.
Linear, as `FMT003`'s single byte pass and `FMT004`'s single codepoint fold are by construction. The
clean input is scan-clean on purpose: the engine's shared post-scan `qsort` (`Rules.findingOrder`,
O(m log m) in the finding count m) then contributes nothing, so the number is the scan itself and not a
sort the source family did not introduce.

### Findings fire at scale, worker-free

The dense input — one control byte and one bidi mark per short block — reports **32,768 findings over
311,296 bytes** in the one test process. It is deliberately *not* timed for the linear claim: its cost
is dominated by the shared finding-sort, not the scan. (A 2.5 MB all-marks input costs ~5 s, all of it
that O(m log m) sort; the scan over the same bytes is ~13 ms. The distinction is why the linear
assertion measures clean input.)

### End-to-end, on committed bytes

`check --json --no-cache tests/check/Security.lean` (exit 1) reports exactly, position-sorted:

```
FMT004  [17,20)  suspicious bidirectional control U+202E
FMT003  [45,46)  forbidden control byte U+0000
```

Both report-only (no `fix`), `withheldUnsafe=0`, `written=0`. This exercises the whole path — read,
`crlfToLf` normalize, `SourceFacts`, rule run, report — not just the scan the unit and property tests
cover. Git stores the fixture as binary (the NUL), so `git diff --check` skips it rather than flagging
it, and it is excluded from every `lean_lib` root so `lake build` never compiles it.

## Decisions changed while auditing

- **The dense/all-findings case is reported, not asserted linear.** An all-marks input is O(m log m) in
  the shared engine sort, which `ruff-05` owns and every rule already pays. Timing it would test that
  sort under the source family's name; the clean regime measures the scan the roadmap's linearity claim
  is actually about. This mirrors `RLC-FINAL`'s split of the fit test from the Θ(n²) output it feeds.
- **The linear proof also asserts a flat per-byte cost between adjacent doublings**, not only the end-
  to-end 8× ratio. An end-to-end bound alone can be met by a superlinear step that a later step
  compensates for; the per-doubling check closes that.

## Remaining uncertainty

- **`ruff-01` precision gap** (LF/CRLF-intermixed accepted-but-classified-`.crlf`) is unchanged and
  still handed off; write safety holds via `ruff-01` round-trip invariant 4 (`notes/01-catalog.md` §4).
  Not this stack's to fix.
- The `FMT003` set stays frozen conservatively (C0-minus-TAB/LF plus DEL). No corpus evidence surfaced
  here argued for widening it; doing so would reopen `notes/01-catalog.md` rather than drift.

## Final source-rule catalog

The family `lean-fmt` ships, complete:

| code   | meaning                            | tier   | category | default | fixable | severity |
| ------ | ---------------------------------- | ------ | -------- | ------- | ------- | -------- |
| FMT001 | remove trailing horizontal whitespace | source | text     | on      | yes     | warning  |
| FMT002 | require a final newline            | source | text     | on      | yes     | warning  |
| FMT003 | forbidden control byte             | source | security | on      | no      | warning  |
| FMT004 | suspicious bidirectional control   | source | security | on      | no      | warning  |

FMT001/FMT002 are the pre-existing formatting rules (canonical formatting subsumes their visual
effect; kept for compatibility). FMT003/FMT004 are this stack's additions: honest byte-level
security scans, report-only because the byte lives inside string data or a comment. The two rejected
candidates — UTF-8 BOM and mixed line endings — carry no honest byte-level semantics over accepted
normalized source (`notes/01-catalog.md` §4) and ship as nothing, which the roadmap's "add **only**
honest source-global rules" requires.
