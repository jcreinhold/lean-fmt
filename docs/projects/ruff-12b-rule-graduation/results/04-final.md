---
claim_id: RGR-FINAL
status: verified
depends_on: [RGR-IMPL]
---

# RGR-FINAL — the catalog `ruff-20` accepts

> **Amendment — the codes below are pre-renumbering.** After this note was verified, the live catalog
> was renumbered to start at `FMT001` (`docs/rules/MIGRATION.md`); every code shifted down by two, so
> `FMT013` here is `FMT011` today and `FMT003` here is `FMT001`. The tables are left as they were
> because they record what the catalog was when this stack decided it — the *decisions* are unchanged,
> only the labels moved. `ruff-20` should audit against live `lean-fmt rules` output, using the
> migration table to map anything quoted here.

This note is the catalog as shipped. It is written to be read **without** the three result notes
before it, because `ruff-20-acceptance` audits against this table and a table that only makes sense
with three other documents open is a table nobody will check.

## 1. The catalog as shipped

Generated from the built binary (`lean-fmt rules`, `lean-fmt explain <code>`), not transcribed from
a record.

### Default — what runs when you type `lean-fmt check`

Five rules. All are source or import tier, so a default run needs **no compiler frontend**: the file
was already read to get here. That is not an accident of which rules happen to be good; it is the
cost policy of RGR-SPEC §5, and §2 below shows what leaving it would cost.

| Code | Category | Tier | Lifecycle | Fixable |
| --- | --- | --- | --- | --- |
| FMT003 | security | source | stable | no |
| FMT004 | security | source | stable | no |
| FMT005 | imports | source | stable | **yes** |
| FMT006 | imports | source | stable | no |
| FMT007 | imports | source | stable | no |

### Stable, off by default — the `stable-optional` outcome

One rule. Reachable by its code, by its category, and by `--select all`, **without** `--preview`.

| Code | Category | Tier | Lifecycle | Default | Fixable |
| --- | --- | --- | --- | --- | --- |
| FMT013 | redundancy | syntax | stable | **off** | **yes** |

FMT013 is the only rule in the catalog whose correctness was judged sufficient to freeze its meaning
while its cost kept it off the default path. Those are separate axes and the catalog expresses them
separately. Selecting it on an ordinary-built project costs one compiler frontend run per module —
measured, not estimated, in §2.

### Preview — nine rules, each with a stated condition for leaving

Reachable only under `--preview`. Every one of these strings is in the shipped binary
(`lean-fmt explain <code>`), in `docs/rules/<code>.md`, and in the JSON; a catalog invariant fails
the build if a preview rule lacks one or a non-preview rule carries one.

| Code | Category | Tier | Fixable | Graduates when |
| --- | --- | --- | --- | --- |
| FMT008 | docs | syntax | no | 10 audited TPs, 0 FPs on a corpus not already enforcing module docstrings in CI, **and** lean-fmt's own tree either complies or the rule excludes executable/script modules — it fires 17 times on lean-fmt's own 34 modules today |
| FMT009 | structure | syntax | no | the whole-file **named** namespace case is settled first (it already exempts the whole-file *anonymous* section), then 10 audited TPs, 0 FPs |
| FMT010 | redundancy | syntax | **yes** | 10 audited TPs, 0 FPs on a corpus that is not attribute-reviewed — generated, student, or unlinted code. Its fix already passes the safety/idempotence/convergence/composition audit |
| FMT011 | redundancy | syntax | **yes** | as FMT010, for duplicate `deriving` classes |
| FMT012 | debug | syntax | no | 10 audited TPs, 0 FPs on a corpus with no `set_option` linter of its own — which mathlib, by construction, cannot supply |
| FMT014 | deprecation | semantic | **yes** | 10 audited TPs, 0 FPs on a corpus that actually uses deprecated declarations. Graduation would enable the **report only**; the rename fix stays `unsafe` and opt-in regardless |
| FMT015 | unused | semantic | no | 10 audited TPs, 0 FPs on a corpus not already `linter.unusedVariables`-clean |
| FMT016 | unused | semantic | no | as FMT015, for a corpus not running `linter.unusedSectionVars` |
| FMT017 | naming | semantic | no | 10 audited TPs **and** a measured opinionation rate (RGR-SPEC §2.4), not just a false-positive rate — this is the rule most likely to be true-but-unwanted |

Eight of these nine scored **zero findings** on 85 real mathlib modules. That is not nine rules
failing an evidence bar independently; it is one fact about the corpus, and it is why every condition
above names the corpus rather than only a number. mathlib runs its own linters for most of what these
rules check — `linter.style.setOption` is FMT012's near-equivalent, `linter.unusedVariables` is
FMT015's. The run measured which rules mathlib already enforces. It did not measure which rules are
correct.

### Retired and meta

| Code | Class | Disposition |
| --- | --- | --- |
| FMT001 | retired | line-boundary normalization is now part of canonical formatting; run `format` |
| FMT002 | retired | trailing-newline normalization is now part of canonical formatting; run `format` |
| FMT900 | meta | a suppression directive suppressed nothing. Always active, never selectable, not suppressible |
| FMT901 | meta | a comment opens with the `lean-fmt:` sigil but does not parse as a directive |

Fifteen live rules, two retired codes, two meta self-diagnostics. `explain` answers for all nineteen
with exit 0; only a never-assigned code (FMT999) errors.

## 2. The shipped catalog, run

`experiments/run-shipped-catalog-sample.sh` over the frozen 62-module mathlib sample,
`ordinary-built` (mathlib built, but **not** with `LeanFmtCompilerPlugin`), `--no-cache` so each arm
is cold. Counts only — `tests/performance/run.sh` owns cost, and RGR-SPEC's variance policy is why a
wall time measured here would not mean anything.

| arm | findings | codes | broken | rejected | infra failures |
| --- | --- | --- | --- | --- | --- |
| `--select default` | **27** | 1×FMT006, 26×FMT007 | 0 | 0 | 0 |
| `--select all` (no `--preview`) | **28** | 1×FMT006, 26×FMT007, **1×FMT013** | 0 | 0 | 0 |
| `--select all --preview` | **28** | 1×FMT006, 26×FMT007, 1×FMT013 | 0 | 0 | 0 |

**The control holds.** The `default` arm reproduces CP-2's baseline exactly — 27 findings, same
composition. Nothing moved in the default set between measuring the catalog and shipping it, which is
what this arm exists to establish.

**The one-finding gap is the whole of what this stack changed, observed end to end.** Before
`ruff-12b` these two arms were byte-identical, because every stable rule was default-on and `all`
therefore expanded to exactly `default`. They now differ by exactly one FMT013 finding on real
mathlib source. `stable-optional` is not a state described in a result note; it is a state the binary
occupies and a user can observe with two commands.

**`--preview` adds nothing on this manifest, and that reproduces `RGR-EVIDENCE`.** The third arm is
byte-for-byte the second: unlocking all nine preview rules over 62 real mathlib modules produces zero
additional findings. `RGR-EVIDENCE` reported 2 preview-tier findings over **85** modules — FMT013's,
which is now stable and appears in the second arm, and FMT009's in mathlib
`scripts/create_deprecated_modules.lean`, which is not in this 62-module manifest. So the expected
count for *this* manifest is exactly one preview-tier finding, it is FMT013's, and FMT013 is no
longer preview. The arms agree.

That agreement is the check this prompt exists to run, and it passes. But the reading that matters is
the uncomfortable one: nine rules unlocked against 62 real modules of a major Lean project found
**nothing**. §1 says why — mathlib enforces most of what they check — and §7 says what `ruff-20`
should do about it.

### A failed run, and why it was mine and not the product's

An earlier invocation of this harness reported three infrastructure failures reading
`could not execute external process '/Users/.../.lake/build/bin/lean-fmt'`. That was me running
`lake build` while the arm was in flight — the binary the harness had resolved was replaced underneath
it. Exit 2 was correct behaviour. Recorded because a reader who finds that report should not have to
re-derive why it failed, and because the re-run above is the citable one.

## 3. Cost policy as shipped

Unchanged from RGR-IMPL, and unchanged *because the default set is unchanged*:

- **`ordinary-built`.** The default set needs no frontend. Adding one syntax-tier rule was measured at
  **33.0× the five-rule baseline against a 1.25× budget — 1 frontend child versus 62**
  (`results/03-graduate.md` §4). That measurement is why FMT013 is `stable-optional` and not default,
  and it is what `ruff-10b`'s deferred Design B decision was refused with.
- **`formatter-integrated-built`.** `tests/performance/run.sh` §1 is this workload, and it passes:
  all 34 targets are index hits and served, with **zero `exact_child` and zero `exact_setup`**.
- **Warm.** CP-1 (`evidence/02-cp1-warm-serve.md`) showed the content-keyed cache serves a tier above
  source on a warm hit, non-vacuously: the all-ten arm emitted 17 findings on a fully-served,
  zero-`exact_child` run, byte-identical to cold.

## 4. `ruff-19`'s gates as shipped

No gate was re-derived, because no gate changed meaning: §1c asserts zero `exact_child`/`exact_setup`
on a served workload, and that holds for its original reason — every default rule is source or import
tier. There is therefore no re-derived gate needing a fresh negative test.

`tests/performance/run.sh` passes, and its §0 is `negative.sh`, which proved **all 16 gates
discriminate before the suite reported that none failed**. A gate nobody has seen fail is not a gate,
and §0 exists so that sentence stays false here.

## 5. Documentation surface — two defects found and fixed

Prompt 04 asks whether the documentation surface agrees with the catalog. It did not, in two places.

**`explain` denied a code the product prints.** `lean-fmt explain FMT900` answered
`unknown rule: FMT900` with exit 2. FMT900/FMT901 carry messages and fixes and appear in reports; a
user meets FMT900 by reading it in output and then looking it up. The cause was a category error:
these codes are absent from `ruleRegistry` because they are never *selectable*, and `explain` read
that absence as non-existence. Fixed with a third table, `metaCodes`, read only by `explain` — the
registry would make them selectable and `reservedCodes` would call them retired, and both are false.

`tests/catalog/run.sh` is what shows this was a defect rather than a choice: its own section header
already listed "live / retired / **meta** / unknown" as the classes `explain` answers for, while the
assertion three lines below pinned FMT900 to exit 2. The prose stated the intent and the assertion
contradicted it. Both now agree, and FMT901 gained coverage it never had.

**`docs/adding-a-rule.md` never documented `lifecycle` at all.** Its canonical `RuleInfo` block
omitted the field, so after RGR-IMPL a contributor who copied it and set `.preview` would hit catalog
invariant 3b with nothing in the guide explaining the failure. Added the four-combination table, and
said the thing a reader would otherwise get backwards: **`.preview` means *unjudged*, not *costly***.
The wrong reading sends the next expensive-but-correct rule to preview and strands it there, because
preview has an evidence bar to clear and expense has none.

**Counts swept repository-wide.** `ruff-20-acceptance`'s state said ten of fifteen rules sit in
preview; nine do. Corrected, with the point a bare count change would have hidden: FMT013 left
preview **without** becoming default, so the concern that paragraph raised is not resolved — nine
rules are still gated off and the default set is still the same five. `ruff-10`'s and `ruff-12`'s
result notes say "six preview rules" and "ten preview rules"; those were true when frozen and are
records of decisions those prompts made, so they were left alone (`CLAUDE.md`: amend a result, do not
retroactively edit one to match a later stack). `tests/syntax/run.sh`'s comment called FMT008–013
"the six preview rules" and was corrected to "six syntax-tier rules" — the mechanism it describes,
naming each code explicitly rather than relying on `--preview`, is unchanged.

## 6. Checks

`LEAN_NUM_THREADS=1 lake build` ok · `lake exe lean-fmt-tests` ok · `lake lint` 35 files, 0 findings,
0 infrastructure failures · `lake exe lean-fmt docs --check` 17 files up to date · `git diff --check`
clean.

**All 21 suites in `tests/*/run.sh` pass:** boundary, cache, catalog, check, ci, compiler, discovery,
downstream, imports, layout, lossless, modes, performance, printer, reporting, scale, semantic,
stream, suppression, syntax, watch.

Structural checkers: the same five pre-existing `implementation_route` failures every lean-fmt stack
reports, including the closed and verified `ruff-06` and `ruff-12`. No new stack-shaped failure.

### `tests/printer/run.sh` failed first, and that is worth recording

The two declarations §5 added to `LeanFmt/Rules.lean` moved this repository's own command count from
1,035 to 1,037 — and **this repository is the printer's corpus**. `ruff-03`'s `RLF-FINAL` chain
caught it:

```
FAIL the shape evidence is stale: it reports 1035 commands, the live corpus has 1037.
     Re-run experiments/run-projection-shape.sh; every figure quoted from it is now wrong.
```

That is the chain working exactly as designed. The edit was a rule-catalog fix with nothing to do
with layout, made by a prompt that had no reason to think about printer figures — which is the
failure mode `RLF-FINAL` names in its own comment: `RLF-EXTENSIONS` once left three files quoting a
node count from two prompts earlier, and nothing failed because nothing was looking.

Repaired by re-running the probe and then its second link. Both edited modules were re-probed
**individually** rather than assumed, per the method `01-coverage-agreement.txt` documents:
Rules.lean 90/90, Cli.lean 80/80. Neither joins the disagreement list, so the printer/probe gap is
still exactly +1 for the two documented causes. 927/926 → 929/928 over the same 28 modules, and 21
stale prose figures across `ruff-03`'s notes and state were updated (32 now checked and agreeing).

A process note, because it nearly shipped a half-repair: my first pass used `sed` with `\b`, which
BSD `sed` does not support, so the word-boundary substitutions silently did nothing while the
comma-formatted ones applied. `check-quoted-figures.py` caught the inconsistent state. A tool that
fails loudly on a partial edit is worth more than one that tidies it away.

## 7. What `ruff-20` inherits

- **A catalog that is decided, not a catalog that is good.** Nine of fifteen rules remain gated off.
  What changed is that each gating is now a recorded decision with a falsifiable condition attached,
  rather than an unexamined default.
- **An evidence problem, stated.** No rule reached RGR-SPEC §2.2's bar of 10 audited true positives;
  the highest any rule reached is 1. The bar was not lowered, and `results/02-evidence.md` carries a
  section naming which criteria were *not* revised so a reader can check that claim rather than take
  it.
- **A corpus that cannot settle this.** Eight rules scored zero on mathlib because mathlib enforces
  most of what they check. `ruff-20` holds the only licence to run full mathlib, and full mathlib is
  *more* of the same corpus — it will not convert those zeros into evidence. The nine conditions name
  the corpora that would.
- **Two open rule defects**, recorded and deliberately unrepaired (prompt 02 forbade repairing a rule
  to make it pass): FMT009 does not carve out a whole-file *named* namespace though it carves out the
  whole-file *anonymous* section, and lean-fmt's own 34 modules violate FMT008 seventeen times.

## 8. Remaining uncertainty

Carried forward from `results/03-graduate.md`, none of it closed here:

- **The baseline's single `exact_child` is unexplained.** Not an error path — 0 broken, 0
  infrastructure failures — but I did not establish what spawns it. The CP-2 conclusion does not
  depend on the answer: 1 versus 62 is structural at any value of 1.
- **CP-4's 0 ms is a measurement without a mechanism.** RGR-SPEC §5.5 predicted a ~101 ms
  `official_artifacts` tax; this workload showed none. I decline to claim a cause I have not shown.
- **CP-3 was never measured** and is a gap, not a pass. Nothing binds it while no rule reaches default.
- **Nine graduation conditions are unexercised.** Each is falsifiable and unfalsified. That is the
  honest state; it is not evidence that any of the nine is correct.
