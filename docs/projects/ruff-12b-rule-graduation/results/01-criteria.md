---
claim_id: RGR-SPEC
prompt: 01-criteria
status: verified
---

# RGR-SPEC — Freeze the graduation criteria and the default-path cost policy

## What this claim delivers

The standard FMT008–FMT017 are judged against, frozen before any rule is measured: the available
outcomes (§1), the false-positive budget and audit method (§2), the fix safety and idempotence
standard (§3), the documentation standard (§4), the default-path cost policy (§5), and the named
corpus (§6). `RGR-EVIDENCE` cites these sections by number and does not revise them; `RGR-IMPL`
applies the verdicts they produce.

**Read §0 first.** It records prior exposure to a firing count and names the one criterion that
exposure could have contaminated.

## §0 — Disclosure: I had seen an aggregate firing count before writing this

The prompt requires that criteria written after seeing firing counts say so and be treated as
suspect. They were, partly.

While reading the prerequisite results as the prompt directs, I read
`ruff-12-rule-lifecycle/results/03-acceptance.md` §"Precision review", which reports the ten preview
rules run together over the same 62-module frozen sample this stack will use, at mathlib
`v4.33.0-rc1`: **0 broken files, 0 infrastructure failures, exactly one finding** — a true-positive
FMT013 (`((ϕ i x))`) in `Mathlib/GroupTheory/NoncommPiCoprod.lean:173` — and zero false positives.

So I knew, before writing §2, that the ten rules together fire about once on this corpus. I did not
see per-rule counts for the other nine, and I have run nothing myself.

**The contaminated criterion is §2.2's exposure threshold**, the only number a known-low count could
have been tuned to. Two things a reviewer should check:

1. I set it from a stated principle — a rule must have had a chance to be wrong on code its author
   did not write — and not by reading back from the observed count.
2. I set it at **10**, knowing that number is very likely unreachable by every one of the ten rules.
   That is tuning *against* the outcome that would be convenient to write up, not for it. If §2.2
   had been reverse-engineered to let rules through, it would be 1.

The rest of the criteria are not exposed: an aggregate count of one says nothing about fix
idempotence, documentation, or cost.

I also note a live-code check, not a firing measurement: `lean-fmt rules` against the built binary
reproduces `state/current.md`'s catalog table exactly — 15 live rules, 5 default, 10 preview, tiers
as recorded. Recorded state and code agree; no prerequisite needs reopening on that basis.

## §1 — The available outcomes

Four, and no others. Each is a concrete pair of catalog fields, so a verdict is applied without
interpretation.

| Outcome | `lifecycle` | `defaultEnabled` | Reachable by | Meaning |
| --- | --- | --- | --- | --- |
| **default** | `.stable` | `true` | `default`, `all`, category, code — no gate | Meaning frozen; runs for users who did not choose it |
| **stable-optional** | `.stable` | `false` | `all`, category, code — no gate | Meaning frozen; runs only when asked for |
| **preview-with-path** | `.preview` | `false` | code or category **under `--preview`** | Unproven; carries the stated condition that would graduate it |
| **retired** | — (no `RuleInfo`) | — | nothing; selector yields a disposition notice, exit 0 | Withdrawn; code never reused |

### §1.1 `stable-optional` is the fourth outcome, and it needs no new machinery

The roadmap named three outcomes and permitted a fourth if defined precisely. This is it, and it is
already implemented — it is simply an unoccupied state, because every `stable` rule today is also
default-on.

`LeanFmt/Config.lean:668-671` resolves selectors as:

```
gated := info.lifecycle == .stable || (info.lifecycle == .preview && preview)
"all"     → gated
"default" → info.defaultEnabled
category  → gated && category matches
```

So `.stable` with `defaultEnabled := false` means exactly: **reachable by `all`, by its category, and
by its exact code, with no `--preview` flag; absent from `default`.** No code change is required to
occupy it; `RGR-IMPL` sets two fields.

This matters because `lifecycle` and `defaultEnabled` are orthogonal by construction
(`LeanFmt/Rules.lean:200-203`) and the catalog invariant only forbids the *converse* — a preview or
deprecated rule that is default-on (`LeanFmtTest.lean:896-900`). Nothing forbids a stable rule that
is default-off.

### §1.2 What `default` costs a rule, beyond correctness

Graduating to `default` requires `.stable`, and `.stable` is a **meaning-freeze promise**: the rule's
meaning may not change afterwards without a new code (`LeanFmt/Rules.lean:150-152`). `ruff-12`
declined to promote any of the ten for exactly this reason — "`stable` is a meaning-freeze promise
not yet earned" (`ruff-12-rule-lifecycle/results/03-acceptance.md`).

So a `default` verdict asserts two independent things: the rule is right, and we are willing to never
change what it means. `RGR-EVIDENCE` must find evidence for both. A rule whose message wording,
threshold, or scope is still being tuned fails §1.2 regardless of its false-positive count.

### §1.3 `deprecated` is available but is not a graduation outcome

`.deprecated` exists and works, but it means *superseded*, and the catalog invariant requires a
`replacement?` naming a live or reserved code (`LeanFmtTest.lean:899-905`). It is the right outcome
only if one of the ten is subsumed by another rule or by canonical formatting. Absent a successor, a
withdrawn rule is **retired**, as `FMT001`/`FMT002` were.

### §1.4 "Default when integrated, optional otherwise" is REFUSED

The prompt requires this be made available or explicitly refused. **It is refused**, on three
grounds:

1. **It makes a linter's findings depend on invisible build state.** The same source, the same
   `lean-fmt.toml`, the same command would produce different findings for a developer whose project
   is plugin-integrated and one whose is not — and CI would disagree with local. A linter whose
   output depends on something the user cannot see in its own configuration is not one whose output
   a reader can act on.
2. **The catalog must be printable without a project.** `lean-fmt rules`, `lean-fmt explain`, the
   generated docs under `docs/rules/`, and `docs/rules/schema.json` all report `default` as a static
   fact, and they work with no Lake setup at all. Making `defaultEnabled` build-state-dependent makes
   the catalog unanswerable outside a workspace, and makes every generated doc page conditional.
3. **`stable-optional` already delivers the honest part of it.** A rule that is correct but too
   expensive for the default path can be promoted out of preview, made selectable by `all` and by
   category with no flag, and documented as trustworthy. An integrated project opts in with one line
   in `lean-fmt.toml`. What it does not get is the appearance of a decision the product made on the
   user's behalf using information the user cannot see.

Consequently there is nothing for a user to "discover about which they are getting": build state
never changes which rules are default.

### §1.5 A `preview-with-path` verdict must state a checkable condition

"Not yet" is not a verdict. A rule that stays in preview records the condition that would graduate
it, in a form someone could later test. Acceptable: *"graduates when it produces ≥10 audited true
positives with zero false positives on a corpus that contains X"*; *"graduates when §5's ordinary-built
cost policy is met, which today requires Design B or plugin integration"*. Not acceptable: *"needs
more evidence"*, *"revisit later"*.

§4.3 fixes where that condition lives so a user sees it.

## §2 — The false-positive budget and the audit method

### §2.1 The budget

**Zero false positives in the audited sample**, for `default` and for `stable-optional` alike. A
single false positive on hand-audited real code disqualifies a rule from both, per the roadmap's stop
rule. It does not automatically retire the rule; it makes the maximum available outcome
`preview-with-path`, and the verdict records the defect.

A false positive is a finding a competent Lean author reading the source would call wrong: the rule
fired where its own stated contract says it should not, or its contract is wrong about the language.
A finding that is *correct but unwanted* — true under the rule's contract, and a reasonable author
would still not change the code — is not a false positive. It is recorded separately as an
**opinionation finding**, and it counts against `default` (§2.4) but not against `stable-optional`.
That distinction is where most of the real disagreement about these ten rules will live, so it is
named before the audit rather than argued during it.

### §2.2 Exposure: how much real code a rule must have faced

Precision is meaningless without exposure. A rule that fires zero times has not shown it is safe; it
has shown the corpus does not exercise it.

- **`default` requires ≥ 10 audited true positives on real code** — the frozen sample and the named
  stress files (§6.1, §6.2) — with zero false positives among them.
- **Focused fixtures do not count toward the 10.** A fixture is written by the same person who wrote
  the rule and demonstrates only that the rule does what its author intended, which is the claim under
  test, not evidence for it. Fixtures remain required (§3, §4) and are the right place to exercise
  malformed, Unicode, custom-syntax, and boundary cases.
- **A rule below 10 real-code findings may still reach `stable-optional`** if every finding it did
  produce audits clean, and its focused-fixture suite covers positive, negative, malformed, Unicode,
  and custom-syntax cases. This is the roadmap's required asymmetry, stated as a number: an opt-in
  rule may be adopted on a fixture suite plus a clean small sample; a rule imposed on people who did
  not choose it may not.
- **A rule with zero real-code findings** cannot reach `default` or `stable-optional`. Its available
  outcomes are `preview-with-path` — whose stated condition should name the corpus that would exercise
  it — or `retired`, if no such corpus plausibly exists among lean-fmt's users.

The threshold is 10 because it is the smallest count at which a clean audit is more than anecdote,
and because the roadmap's own precedent is one hand-reviewed finding being treated — correctly — as
too thin to promote on. See §0: this number is the one exposed to prior knowledge.

### §2.3 Audit sample size and sampling method, fixed before any finding is read

- Let `F` be the rule's total findings over the frozen sample plus the named stress files.
- If `F ≤ 30`, **audit all of them**.
- If `F > 30`, audit the **first 30 in deterministic report order** (path ascending, then line, then
  column) — not a random sample. At these counts, reproducibility by a later reader is worth more
  than statistical purity, and a stated deterministic rule cannot be re-drawn after an inconvenient
  result.
- Auditing means reading the finding against the source it fired on and judging it as a competent
  Lean author would, one of: true positive, false positive, or opinionation finding (§2.1).
- Every audited finding is recorded in `evidence/` with `path:line`, the emitted message, and the
  verdict with a one-line reason. `ruff-12`'s precision run wrote its raw outputs to a gitignored
  directory and they are therefore not citable; `RGR-EVIDENCE` must not repeat that.

### §2.4 Opinionation, and the additional bar for `default`

A `default` rule is read by people who did not choose it, so it must also clear:

- **Zero opinionation findings in the audited sample**, or a recorded argument for why the flagged
  code should in fact change. A default rule that is technically right and routinely ignored trains
  users to ignore the whole tool.
- **A stated suppression story**: §4.2 requires the explanation say when a competent author should
  ignore the rule. If no such case exists, say that; if it is common, the rule is opinionated and
  belongs in `stable-optional`.

## §3 — The fix safety and idempotence standard

Applies to every fixable rule under judgement: FMT010, FMT011, FMT013, FMT014. (FMT005 is already
default and is not under judgement here.)

- **FX-1 — Safe under `ruff-06`'s definition.** Safe means *meaning-preserving under the rule's stated
  contract*, not "the result reparses". `ruff-06-fix-safety/notes/01-model.md` §1 fixes this, and
  `results/01-model.md` records that "the candidate parses" was the first framing and was rejected as
  exactly the error the stop rule forbids. A fix that cannot be argued meaning-preserving is `unsafe`
  and its rule does not graduate to `default` with the fix enabled by default.
- **FX-2 — Idempotent.** `fix` applied twice yields bytes identical to `fix` applied once, checked
  with `cmp`, on every corpus file where the rule fired and on every fixture.
- **FX-3 — Convergent in one pass.** After one `fix`, the file yields zero further findings of that
  rule.
- **FX-4 — Still elaborates.** The result parses and elaborates under the exact module setup, through
  the existing output re-elaboration validator. This is machinery that exists; the criterion is that
  it is exercised on corpus files, not only on fixtures.
- **FX-5 — Trivia-exact.** The fix touches only the bytes its stated edit names. `ruff-06`'s
  byte-level meaning of safe — a safe fix edits trivia even when trivia follows comment text, and
  never eats the comment (`ruff-06/results/03-acceptance.md`) — holds on corpus files.
- **FX-6 — Composition.** Where two selected rules edit one file, `ruff-10b`'s composition tests and
  `tests/syntax/run.sh` are the existing machinery and must pass with the candidate set selected
  together, not one rule at a time.

**FX-7 — the Design B trigger.** If a syntax-tier rule carrying a fix (FMT010, FMT011, FMT013)
reaches `default`, `ruff-10b`'s revisit condition fires verbatim — *"Design B remains the named
optimization if a syntax rule graduates to default and the gated re-projection lands on the default
run cost budget"* (`ruff-10b/results/03-final.md`). `RGR-IMPL` then owes either adoption of Design B
(a parse-only projection of rendered canonical text in place of full re-elaboration,
`ruff-10b/notes/01-model.md:78-90`) or a measurement showing Design A affordable under §5. Refusal
without a measurement is not available.

## §4 — The documentation standard

The catalog invariants already enforce a floor: nonempty explanation, ≥1 executable example,
bad→good for a fixable rule, one generated doc page per live rule, no doc drift
(`LeanFmtTest.lean` invariant 4 at 907-921 and invariant 6 at 927-931). That floor is the
**baseline, not a criterion** — every one of the ten
already meets it, so it discriminates nothing. The criteria are what exceeds it.

- **DOC-1 — Contract, not description.** The explanation states the condition under which the rule
  fires precisely enough that a reader can predict a finding without running it. §2.1's false-positive
  judgement is made against this text, so a vague explanation makes its own rule unauditable.
- **DOC-2 — When to ignore it.** A `default` or `stable-optional` rule's explanation names the case
  where a competent author should suppress rather than comply, or states that no such case exists. A
  rule imposed by default that never admits an exception is one users learn to disable wholesale.
- **DOC-3 — The path out of preview is a field, not prose.** A rule remaining in preview carries its
  §1.5 graduation condition as a first-class `RuleInfo` field, rendered by `lean-fmt explain` and the
  generated doc page, with a catalog invariant requiring it nonempty **iff** `lifecycle == .preview`.
  `RGR-IMPL` implements it; this section fixes the standard. Prose in a result note does not satisfy
  DOC-3 — prompt 03 requires the condition appear "where a user will see it and not only in a result
  note", and an unenforced field rots exactly as `CLAUDE.md` says a declared tier field would.
- **DOC-4 — Retirement names a reason.** A retired rule's `reservedCodes` disposition follows the
  FMT001/FMT002 form: `"retired: <why>; <what to do instead>"` (`LeanFmt/Rules.lean:1002-1006`).
- **DOC-5 — Repo-wide agreement.** `docs/adding-a-rule.md`'s tier guidance, `docs/rules/index.md`,
  `docs/rules/schema.json`, and every rule count quoted in prose anywhere in the repository agree with
  the shipped catalog. `RGR-FINAL` audits this; the criterion is stated here so it is not discovered
  late.

## §5 — The default-path cost policy

This is the half of the stack that is not about correctness. Graduating any of the ten puts a tier
above source on the default path for the first time.

### §5.1 The two measured numbers this policy is built on

Both from `ruff-19-performance/results/02-optimize.md`, on four modules each:

| State | `official_artifacts` | `exact_child` | `setup_prime` |
| --- | ---: | ---: | ---: |
| `formatter-integrated-built` | **105 ms** | **never runs** | — |
| `ordinary-built` | 101 ms (finds nothing) | 2,058 + 370 + 634 + 221 = **3,283 ms** | 100 ms |

> **One Lake traversal replaces four frontend child processes — about 820 ms per module.**

Two caveats `ruff-19` states and this policy inherits verbatim: it "is not a speed benchmark: four
small fixture modules are not a project, and the per-module frontend cost above is dominated by the
first child's 2,058 ms of process and import startup, which the later three do not pay." So the
**marginal** per-module cost is 1,225 ms / 3 ≈ **408 ms**, over a first-child fixed cost of ~2,058 ms.
A run over `M` ordinary-built modules is therefore modelled as `2,058 + 408·(M−1)` ms — a model, not a
measurement, and `RGR-EVIDENCE` measures rather than assumes it.

For the semantic tier, `ruff-11-semantic-rules/results/03-acceptance.md` measured capture as additive
in memory only — 636 → 637 MiB peak RSS, +0.2% — because it normalizes a `MessageLog` the frontend
already assembled. **The capture is cheap; the frontend it rides on is not.** Semantic-tier cost on
the default path is therefore governed by the same frontend numbers above, not by the capture figure.

### §5.2 CP-1 — The warm-served invariant is absolute

A default run on an unchanged, cache-warm project must remain fully cache-served. In `ruff-19`'s
gates (`tests/performance/gates.sh`):

- §1a `cache.targets` equals the manifest file count;
- §1b `cache.index_hits == cache.targets == cache.served`;
- §1c `exact_child == 0` **and** `exact_setup == 0`.

**No graduation may break CP-1.** The reasoning is that the aggregate semantic-result cache is keyed
on content, so a warm repeat run replays results regardless of the tier that produced them — meaning
a graduated syntax- or semantic-tier rule should cost nothing on a warm hit. That is a **prediction,
and `RGR-EVIDENCE` must test it**, not an established fact: it has never been true of this product
that a default rule demanded a tier above source. If a candidate set does break §1c, the correct
reading is that the cache is failing to serve a tier it should serve — a defect to fix or report, not
a cost to accept by relaxing the gate. `ruff-19` re-derives gates with recorded derivations; it does
not loosen them until they stop firing, and any re-derived gate must still discriminate under
`tests/performance/negative.sh`.

### §5.3 CP-2 — The ordinary-built cold budget, in numbers

The binding constraint. On an `ordinary-built` project, the shipped default set may not exceed
**1.25×** the five-rule baseline on the cold path, measured over the frozen 62-module sample under
`ruff-19`'s variance policy (median of ≥3, never the first run, spread reported beside the median,
machine conditions recorded).

- Baseline: `mathlib-sample` `check`, cache-cold, **24,696 ms** (`ruff-19/evidence/01-workloads.md`).
- Ceiling: **30,870 ms**.
- Equivalent per-module form, which is the one to prefer because it does not depend on corpus size:
  the graduated set may add at most **~100 ms per module** of amortized cost above source tier.

Two honest statements about this number:

1. **It is a judgement, not a derivation.** 25% is where a cold CI lint run's increase stops being
   absorbed and starts being noticed, for rules the user did not ask for. No measurement produces
   that figure; I chose it and am recording that I chose it.
2. **On `ruff-19`'s published numbers it is expected to bind, and that is deliberate.** At ~408 ms
   marginal per module, one syntax-tier rule on the default path would add ~25,000 ms over 62 modules
   — roughly **doubling** the cold run, about 8× the budget. Stating this now, from already-published
   numbers, is not deciding any rule's outcome; it is refusing to write a policy whose implications I
   have not looked at. The three legitimate responses are named in §5.6, and `RGR-EVIDENCE` measures
   rather than assuming this projection holds.

Report `phase.exact_child_ms` and its **count**, `phase.exact_setup_ms`, `phase.official_artifacts_ms`,
and `cache.index_hits` — not wall time alone. `ruff-19` records the same binary over the same warm
corpus at 3,977 ms and 19,968 ms depending only on machine load, so a wall-time-only comparison is
not evidence.

### §5.4 CP-3 — The integrated ceiling

On `formatter-integrated-built`, a default rule above source tier may add:

- **zero** `exact_child` runs, and
- at most **one** `official_artifacts` facet traversal per run — a **per-run** cost, never per-module —
  bounded at **150 ms**, against the 105 ms measured.

If a candidate set produces even one `exact_child` on an integrated project, the plugin is not
serving the tier it exists to serve, and that is a defect to report before it is a cost to accept.

### §5.5 CP-4 — The tax on projects that cannot benefit

`official_artifacts` costs **101 ms on a workspace that cannot possibly have an artifact, and it pays
that before finding nothing** (`ruff-19/results/02-optimize.md`). Today no default run pays it,
because no default rule demands a tier above source. Graduating one moves that 101 ms onto every
default run of every non-integrated project, including ones that will never integrate.

Policy: this cost is **counted against CP-2's budget**, not treated as free. It is accepted outside
CP-2 only if the default path can determine that no artifact can exist and skip the traversal, in
which case the skip must be demonstrated by a count — `official_artifacts` absent from the phase
record — and not by argument.

### §5.6 The three legitimate responses to a rule that fails CP-2

Named now so that none is invented under pressure later:

1. **`stable-optional` (§1).** The rule is correct and promoted out of preview; it simply is not on
   the default path. This costs nothing and is available to every rule that clears §2 and §3.
2. **Adopt Design B (§3 FX-7).** If it makes the re-projection cheap enough to meet CP-2, `ruff-10b`'s
   deferred decision is paid and the rule graduates.
3. **`preview-with-path` whose stated condition is the cost (§1.5).** E.g. *"graduates when CP-2 is met
   on an ordinary-built project"* — a condition a later stack can test.

**Not available:** relaxing CP-2 after measuring; making the default set depend on build state (§1.4);
paying for it with concurrency — `ruff-19` rejected private concurrency on measurement and no public
`-j`, pinning, or strategy flag exists to spend here.

### §5.7 CP-5 — The resource envelope is unchanged

8 GiB aggregate RSS, normal pressure, 256 MiB new swap. `ruff-11`'s semantic gate — capture-on
< 8 GiB and ≤ 1.5× capture-off (`tests/semantic/run.sh:519`) — continues to apply. Nothing in this
stack may raise these.

## §6 — The corpus, named

### §6.1 Primary: the frozen mathlib sample

`experiments/workloads/mathlib-v4.32.0-sample.txt` — **62 modules**, selected from mathlib4 at
revision `783ccda4ee524f13cc5636237be0a1942bc04824`, toolchain `leanprover/lean4:v4.32.0`, out of
8,795 files, manifest digest
`1936bdb60e01c14fdc986a535ef9317d63775506708e35f4155a9c4c5c6eeeef`.
`experiments/select-mathlib-workload.sh:7-12` hard-fails unless the checkout matches these pins.

**Revision drift, disclosed.** `ruff-19` and `ruff-12` both measured against mathlib `8c79cb4f…` on
`v4.33.0-rc1`, not the `783ccda4…`/`v4.32.0` revision the 62-file list was frozen against; all 62
paths still exist at that commit, and rebuilding at the old revision was judged unjustified. The
baseline numbers this policy cites therefore come from `v4.33.0-rc1`. `RGR-EVIDENCE` must record which
revision it actually ran, and treat any cross-revision comparison as **same-shape, not same-run**, in
`ruff-19`'s own phrasing.

### §6.2 Named stress files

- `experiments/workloads/mathlib-v4.32.0-stress-largest.txt` — `Mathlib/Analysis/Normed/Module/Multilinear/Basic.lean`, 63,748 bytes.
- `experiments/workloads/mathlib-v4.32.0-tactic.txt` — `Mathlib/Tactic.lean`.
- `experiments/workloads/mathlib-v4.32.0-attr.txt` — `Mathlib/Data/Finset/Attr.lean`; the attribute-dense
  file, and the one most likely to exercise FMT010.
- `experiments/workloads/mathlib-v4.32.0-batch-8.txt` (8) and `-remainder.txt` (12).

### §6.3 Self, and the two build states

`experiments/workloads/lean-fmt-self.txt` — 34 modules, this repository. It is the corpus
`tests/performance/run.sh` uses and the only one for which **both** build states are cheaply
reachable, so it carries the §5.3/§5.4 before-and-after. `ruff-19`'s integrated workload is
`tests/compiler/LocalSyntax.lean` and `tests/check/{Clean,Findings,Layout}.lean`, built with
`LeanFmtCompilerPlugin` (`ruff-19/evidence/01-workloads.md` §3.1).

Note that `lean-fmt-self.txt` is *this repository's own code*, so findings on it are not independent
evidence about a rule's precision in the §2.2 sense — the rules and the code were written by the same
project. It is cost evidence, not exposure evidence.

### §6.4 Focused fixtures

The `tests/*/` fixture trees, plus new fixtures a rule needs to exercise a case the corpus does not
contain. Required by §3 and §4; **excluded from §2.2's exposure count** by design.

### §6.5 The existing runner

`experiments/run-lifecycle-precision-sample.sh` is the harness `ruff-12`'s RRL-FINAL used over all ten
preview rules on this sample. Reuse it rather than writing a new one, and fix it if it is wrong.

### §6.6 Forbidden

The complete 8,795-file mathlib. That licence is `ruff-20-acceptance`'s alone. A graduation decision
that can only be made with the full corpus is a decision to defer to `ruff-20`, and the verdict says
so rather than guessing.

## What this prompt did not do

No rule's firing behaviour was measured, and no rule's outcome was decided — including FMT013, whose
single audited true positive is already on record from `ruff-12` and which this note deliberately does
not treat as a verdict. Ten `preview-with-path` conditions, four fix audits, and the CP-2 measurement
are `RGR-EVIDENCE`'s.

## Checks read

| Check | Result |
| --- | --- |
| `LEAN_NUM_THREADS=1 lake build` | exit 0 |
| `lake exe lean-fmt rules` | 15 rules; matches `state/current.md` exactly |
| `lake exe lean-fmt explain FMT010` | renders lifecycle, tier, default, fix, example, docs path |
| `git diff --check` | clean |
| `check_stack.py … --structural` | 5 errors, 4 warnings — **all `implementation_route`**; see below |
| `write_next.py --check` | `error: no formalization policy above …` — see below |

No module boundary changed (this prompt is docs-only), so `tests/boundary/run.sh` has nothing new to
inspect; it is `RGR-IMPL`'s to run against a real change.

### Structural checker disagreement, and how it was settled

`check_stack.py` and `write_next.py` are the KanProofs tooling, and both now fail on this stack. The
failures are **not** this stack's: run against the closed, verified `ruff-06-fix-safety` and
`ruff-12-rule-lifecycle`, they produce the *identical* five `implementation_route` errors, even though
those stacks' own result notes record "0 warnings" from the same scripts at the time they closed.
`write_next.py` fails earlier still, on a missing "formalization policy" — a KanProofs concept with no
lean-fmt analogue.

So the tooling acquired an `implementation_route` / `Permitted Fallback Triggers` convention after
these stacks were written, and no lean-fmt stack adopts it. Per `CLAUDE.md`'s rule for disagreeing
records: settled by recording it rather than by adding a route block to this one stack, which would
make it inconsistent with every sibling and would encode a convention nobody has decided to adopt
here. The checkers' *stack-shaped* assertions — prompt frontmatter, `depends_on` ordering,
`first_unresolved` agreement — pass. Adopting or discarding the route convention repo-wide is a
decision for whoever next touches `docs/projects/AGENTS.md`; it is out of scope here and is not a
blocker.

## Remaining uncertainty

- **CP-2's 1.25× is a judgement (§5.3).** If `RGR-EVIDENCE` finds a candidate set landing just outside
  it, the honest move is a verdict of "fails CP-2" plus a recorded note that the criterion was close,
  not a revision of the criterion. §0 exists so that a later reader can weigh that.
- **CP-1 rests on a prediction (§5.2)** — that the aggregate result cache serves a tier above source on
  a warm hit. It has never been tested, because no default rule has ever demanded one. If it is false,
  the graduation question changes shape entirely and `RGR-EVIDENCE` should stop and say so.
- **§2.2's exposure threshold may prove unreachable by all ten rules**, given §0. If so, that is a
  finding about the corpus — mathlib is exceptionally clean and runs its own linters, so it is close to
  the worst available corpus for demonstrating that a hygiene rule fires correctly — and `RGR-EVIDENCE`
  should report it as such rather than as ten failures. The remedy available to it is §6.4 fixtures for
  §3/§4 plus a `preview-with-path` condition naming the corpus that would exercise the rule; the remedy
  *not* available is lowering the threshold.
- **The opinionation category (§2.1) is new here** and has no prior use in this repository. It may turn
  out that the distinction between "false positive" and "true but unwanted" is harder to draw in
  practice than §2.1 assumes. Record the hard cases rather than forcing them into a bucket.
