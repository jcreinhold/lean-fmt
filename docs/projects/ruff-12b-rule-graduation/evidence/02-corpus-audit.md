# Corpus run and hand audit — FMT008–FMT017

`results/01-criteria.md` §2.3 requires every audited finding be recorded here with `path:line`, the
emitted message, and a verdict with a one-line reason, because `ruff-12`'s precision run wrote its raw
outputs to a gitignored directory and is therefore not citable. This file is that record.

## Environment

| | |
| --- | --- |
| lean-fmt commit | `2f57619` (worktree clean at run time) |
| lean-fmt toolchain | `leanprover/lean4:v4.33.0-rc1` |
| mathlib4 checkout | `3de5ed81cc71b9ea62597b865ba0baaeb5eb0ea9`, `leanprover/lean4:v4.33.0-rc1` |
| Machine | darwin 25.5.0, arm64 |
| Runner | `experiments/run-lifecycle-precision-sample.sh` (§6.5), `STAMP=rgr-evidence-sample` |

### Revision drift, third instance

§6.1 pins the 62-file manifest to mathlib `783ccda4…` / `v4.32.0`. `ruff-19` and `ruff-12` both
measured at `8c79cb4f…` / `v4.33.0-rc1`. **This run is at a third revision, `3de5ed81…`**, still
`v4.33.0-rc1`. All 62 manifest paths were verified present at this commit before the run.

Comparisons to `ruff-12`'s and `ruff-19`'s numbers are therefore **same-shape, not same-run**, in
`ruff-19`'s own phrasing. The manifest digest pin in `experiments/select-mathlib-workload.sh:7-12` is
against the file list, not the file contents, so it does not detect this.

That the result below reproduces `ruff-12`'s exactly across three different mathlib revisions is
itself evidence — the finding is a property of mathlib and of the rules, not of a particular checkout.

## The frozen 62-module sample

Command (per module, from the runner):

```
LEAN_FMT_DISABLE_ARTIFACT=1 lean-fmt check --root <mathlib> --json --no-cache --preview \
  --select FMT008 … --select FMT017 <module>
```

`LEAN_FMT_DISABLE_ARTIFACT=1` forces the exact frontend, which is the only path that projects a
syntax rule and elaborates a semantic one on unbuilt mathlib modules.

Result (`summary.txt`):

```
modules=62   total_findings=1
  FMT008=0  FMT009=0  FMT010=0  FMT011=0  FMT012=0
  FMT013=1  FMT014=0  FMT015=0  FMT016=0  FMT017=0
broken_modules=0: []
infra_failures=0: []
seconds_total=521.2  seconds_max=40.1
```

**Zero broken modules and zero infrastructure failures across 62 real mathlib modules** is a real
result about the exact frontend's robustness, and it is worth separating from the finding counts: the
runs succeeded, so the zeros are zeros, not silence.

## The audited findings

§2.3: `F = 1 ≤ 30`, so **all** findings are audited.

### 1. FMT013 — `Mathlib/GroupTheory/NoncommPiCoprod.lean:174`

- **Message:** `redundant nested parentheses`
- **Byte range:** 7076–7086 of the normalized source
- **Slice:** `((ϕ i x))`
- **Context:**

  ```lean
  @[to_additive]
  lemma commute_noncommPiCoprod {m : M}
      (comm : ∀ i (x : N i), Commute m ((ϕ i x))) (h : (i : ι) → N i) :
  ```

- **Verdict: TRUE POSITIVE.** `Commute m ((ϕ i x))` and `Commute m (ϕ i x)` are the same term; the
  outer pair wraps a single already-parenthesized application and carries no grouping, precedence, or
  readability role. A competent Lean author would call the outer pair redundant. The same edit was
  independently hand-reviewed by `ruff-10b` (`results/03-final.md`), which also confirmed the module's
  five other `(ϕ i x)` occurrences are already single-parenthesized — so the rule distinguishes the
  redundant case from the necessary one *within the same file*, which is stronger evidence than the
  single count suggests.
- **Not an opinionation finding (§2.1):** removing the pair is what the surrounding code already does
  five times over.

That is the complete audit. There were no other findings to read.

## Per-rule exposure against §2.2

| Rule | Tier | Findings on the 62-module sample | §2.2 exposure |
| --- | --- | ---: | --- |
| FMT008 | syntax | 0 | none |
| FMT009 | syntax | 0 | none |
| FMT010 | syntax | 0 | none |
| FMT011 | syntax | 0 | none |
| FMT012 | syntax | 0 | none |
| FMT013 | syntax | **1** | 1, audits clean |
| FMT014 | semantic | 0 | none |
| FMT015 | semantic | 0 | none |
| FMT016 | semantic | 0 | none |
| FMT017 | semantic | 0 | none |

§2.2's `default` threshold is **10 audited true positives on real code**. The highest any rule reached
is **1**. No rule is within an order of magnitude of the bar.

## This is a finding about the corpus, reported as §2.2 requires

`results/01-criteria.md` §2.2 anticipated this and directed that it be reported as a property of the
corpus rather than as ten rule failures. It is one:

**mathlib is close to the worst available corpus for demonstrating that a hygiene rule fires
correctly.** It runs its own linters — `linter.style.setOption` is FMT012's near-exact equivalent, and
mathlib's CI enforces module docstrings, closed scopes, and deduplicated attributes. A rule that
targets exactly what a heavily self-linted corpus already forbids will find nothing there, and finding
nothing is not evidence of precision. The runner's own header said so before this stack existed:
"mathlib is heavily self-linted for the FMT008-012 and FMT014-017 equivalents (expected near-zero);
FMT013 (redundant nested parens) has no mathlib linter."

FMT013 is the one rule with no mathlib counterpart, and it is the one rule that fired. That is not a
coincidence, and it is the clearest signal in this table: **the corpus measures which rules mathlib
already enforces, not which rules are correct.**

The remedy §2.2 makes available is a `preview-with-path` verdict whose stated condition names the
corpus that *would* exercise the rule. The remedy it does not make available is lowering the
threshold, and this file does not propose lowering it.

## The self corpus, for completeness

`evidence/02-cp1-warm-serve.md` records 17 FMT008 findings over lean-fmt's own 34 modules. Per §6.3
these are **not** exposure evidence — the rules and that code come from one project — but they are
§2.4 opinionation evidence, and the FMT008 verdict addresses them.
