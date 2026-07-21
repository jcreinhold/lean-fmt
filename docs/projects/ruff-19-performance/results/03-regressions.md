---
claim_id: RPR-FINAL
status: verified
depends_on: [RPR-IMPL]
---

# RPR-FINAL — Install durable performance gates

`RPR-IMPL` found three optimizations and two measurement defects. This claim installs what catches
the next ones, and its central design decision is a refusal: **no gate here asserts a wall time.**

## Why not, with the number that settles it

`RPR-IMPL` measured the same unchanged binary over the same warm corpus at **3,977 ms and
19,968 ms** — a 5× spread caused by nothing but what else the machine was doing. `module_evidence`
alone swings 1,687–5,916 ms on page-cache state. A wall-time threshold calibrated on a quiet machine
fails on a busy one, gets raised until it stops firing, and then guards nothing while looking like
it does. The prompt's own stop rule says as much: *"do not encode flaky wall-time thresholds without
calibration."*

So every gate is a **count, a ratio, or a digest** — quantities that do not move when the machine
gets slower. What they catch is a change in the *work performed*, which is what a performance
regression actually is.

## The fast half: `tests/performance/run.sh`

Runs on every commit, finishes in about a second, and is in the `tests/*/run.sh` sweep.

| § | Gate | Form |
| --- | --- | --- |
| §0 | the gate predicates discriminate | 16 accept/reject cases |
| §1a | the run saw all 34 manifest files | count |
| §1b | every target is an index hit and is served | counts |
| §1c | neither `exact_child` nor `exact_setup` runs on a served workload | counts |
| §2 | no work outside the top-level phases (gate G3) | remainder, bounded |
| §3 | `positions` both emits and measures something | count and value |
| §4 | the served report is byte-identical to the report that populated the cache | digest |

**§1c is the strongest single gate.** A fully served run must never reach the exact frontend; if it
does, an input to the cache identity started moving that should not, which is the `ruff-16b` defect
class and the one `RPR-IMPL` spent two optimizations getting off the warm path. It is a count, so it
holds on any machine.

**It primes its own cache in-run.** `tests/cache/run.sh` documents the self-hosting hazard: the index
is named by a digest including the formatter binary's identity, so editing any `LeanFmt/*.lean`
rebuilds the binary, renames the index, and orphans every entry. A gate assuming a warm cache would
fail on every commit that touched the formatter — that is, on every commit it exists to guard.

## Gate G3 was stated as a percentage, and that was under-specified

The suite failed G3 on its first run: **89.0% accounted**, against a 90% bar that `RPR-SPEC` had
measured at 95.1% and 97.2%. Before adjusting anything, I measured the gap five times:

| Wall | Accounted | Unaccounted |
| ---: | ---: | ---: |
| 454 ms | 403 ms | **51 ms** |
| 532 ms | 481 ms | **51 ms** |
| 1,225 ms | 1,158 ms | **67 ms** |
| 454 ms | 403 ms | **51 ms** |
| 453 ms | 403 ms | **50 ms** |

**The remainder is a constant, not a fraction.** It held at ~51 ms while wall ranged 453–1,225 ms.
It is process startup and teardown — binary load, Lean runtime initialization, exit — which no phase
brackets and none should.

That makes the percentage form of G3 workload-length-dependent by construction: a fixed 51 ms is
0.5% of a 10.9 s `mathlib-sample` run and 11% of a 450 ms `self` run. **The published 95.1% and
97.2% figures are exactly what this constant predicts**, so nothing prior was wrong — but stating G3
as a bare percentage, with no workload length attached, could not be applied to a new workload
without silently changing its meaning.

The gate therefore bounds the **remainder**, at 250 ms: about 5× the constant, and above the 67 ms
seen when wall spiked 2.7× under load. It fires when a genuinely unbracketed region of *work*
appears, which is the regression G3 exists to catch, and not when the machine is busy.

One harness defect surfaced on the way. The first attempt took two `python3` timestamps around the
run and put both interpreter startups in the denominator — 68 ms of "unaccounted" time the formatter
never spent. The measurement harness was failing its own measurement, which is the same error class
as the `withPhase <| pure e` defect and worth naming as such. One Python process now times the child
directly.

## Proving the gates can fail: `tests/performance/negative.sh`

A suite that reports "ok" four times against a healthy tree reports exactly what `return 0` would.
A gate nobody has seen fail is an untested claim, and the more reassuring its output the more
expensive the eventual surprise.

So the predicates live in `tests/performance/gates.sh` as functions over file paths, and 16 cases
feed each one input it must accept **and** input it must reject. Both halves matter: a predicate
that always fails catches every regression and is uninstallable; one that always passes catches
nothing and looks perfect. Only the pair pins the behavior.

The predicates are a sourced library rather than inline for exactly this reason — negative tests
that reimplemented the conditions would test a copy, and a copy that drifted would keep passing
while the real gate rotted.

The rejection cases are crafted profile captures rather than provoked breakage: provoking a real
unbracketed region means editing `LeanFmt/*.lean` and rebuilding, which would make the suite mutate
the tree it measures. The predicates read text, so they are handed the text a broken formatter would
emit. Whether the formatter emits that text under real breakage is `run.sh`'s job, on real runs.

The case worth naming: **`positions` emitted but reading 0 ms.** That is the exact signature of the
defect `RPR-IMPL` found, where nothing looks broken and the phase reports 0 ms forever because the
bracket wraps an already-evaluated pure value. §0 runs this proof before the suite reports that
nothing failed.

## The heavy half: `experiments/run-scheduled-gates.sh`

Costs minutes, so it is scheduled rather than per-commit. It adds four things the fast gates cannot
reach:

1. **Cold.** The per-commit suite primes its own cache and so never measures a cold run — where both
   of `RPR-IMPL`'s largest wins were found.
2. **Scale.** 62 mathlib modules exercise `choice` nodes, `#exit`, and token densities that 34
   self-hosted modules do not.
3. **Digest reuse.** Each report is hashed and compared against `experiments/gates/expected-digests.txt`.
   Every speed gate is satisfiable by being wrong faster; this is the one that is not. `--record` is a
   separate explicit act, because a runner that re-recorded on mismatch would report success forever
   while output drifted arbitrarily far.
4. **Saved raw profiles.** Runs go through `profile-run.sh`, which writes `.meta`, `.phases`,
   `.stdout`, and `.stderr` into `experiments/results/` and enforces the 8 GiB / 256 MiB-swap /
   normal-pressure envelope. Those files are what a later stack reads instead of re-running anything.

### Measured on installation

```
cold wall 19,191 ms, 1 frontend child     digest c0dc55c3…
warm walls 4,412 / 4,285 / 3,804 ms       median 4,285 ms, spread 1.16x, digest c0dc55c3…
positions  early 3 ms, late 23 ms, many 32 ms, oneline 24 ms   late/early 7.7x
```

Two independent confirmations fell out of this. The digest `c0dc55c3…` **matches the frozen
`mathlib-sample` baseline in `evidence/01-workloads.md` exactly**, taken weeks and three
optimizations earlier — the strongest available evidence that none of `RPR-IMPL`'s changes moved
output. And late/early reproduced at 7.7× against the 7.5× measured independently in `RPR-IMPL`.

The digest gate was then verified to fail: pointing the expectation at `deadbeef…` produced
`FAIL … the formatter's output moved, which no performance change may do` and a non-zero exit.

## Variance policy

Written into the scheduled runner's header, where whoever reads a number will see it:

- **Never gate on a wall time.** Nothing in either half compares a duration to a threshold.
- **Report the median of at least three**, never a single run and never the first — the first run
  after an idle period reads roughly 1.8× the settled value.
- **Report the spread beside the median.** A median with 5× under it is a different claim from one
  with 5% under it, and printing the median alone hides which you have. The runner prints the spread
  and, above 2.0×, downgrades its own median to an upper bound rather than failing.
- **Record machine conditions.** `profile-run.sh` captures load, swap, and pressure into each
  `.meta`. A number without them cannot be compared to a number taken later.

## Concurrency: rejected

The roadmap requires this claim to record an accept/reject note. `RPR-IMPL` supplies **reject**, and
the evidence is in `results/02-optimize.md`: nine paired repetitions, median B/A **0.954** against a
bar of 0.80, four of nine slower than sequential, aggregate peak RSS doubling to 1.6 GiB. Separately
and independently disqualifying, two sessions publishing one project index are atomic and safe but
**last-writer-wins**, so a concurrent pair leaves roughly half a cache behind and the next run pays
those misses.

No public `-j`, pinning, or strategy flag — and the measurement says there would be nothing worth
exposing behind one. `experiments/run-two-session-concurrency.sh` reproduces the test for whoever
wants to reopen it on an idle machine.

## Remaining uncertainty

- **The scheduled half has no scheduler.** It is a script that a cron job, a CI workflow, or a person
  must invoke; nothing in this repository runs it automatically. Wiring it to a runner needs a CI
  environment with a mathlib checkout, which this stack does not provision.
- **The recorded digests are machine-specific in principle.** They matched a baseline taken weeks
  earlier on this machine, but nothing here proves they hold across toolchain patch versions. The
  first mismatch on a new machine should be investigated before it is re-recorded.
- **`GATE_REMAINDER_BOUND_MS` is calibrated on one workload.** 250 ms suits a 450 ms `self` run. A
  future gate over a much larger workload should re-derive it rather than inherit it, since the
  constant it bounds is a property of process startup and not of the corpus.
- **The generic structural checker still reports 5 errors**, demanding an `implementation_route`
  under a `formalization-policy.yml` that `check_stack.py` resolves out of kan-proofs. `write_next.py`
  reports "no formalization policy above" this stack, and completed `ruff-16` fails identically.
  Recorded in `results/02-optimize.md`; satisfying it would mean fabricating a review fingerprint.
