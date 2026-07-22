# Next Proof Packet

- Stack: ruff-12b-rule-graduation
- First unresolved: none — **the stack is complete**
- Claim ID: —
- Prompt: —
- Target file: —

All four claims are verified: RGR-SPEC (`results/01-criteria.md`), RGR-EVIDENCE
(`results/02-evidence.md`), RGR-IMPL (`results/03-graduate.md`), RGR-FINAL (`results/04-final.md`).

## What the next stack should read

`ruff-20-acceptance` is next in the order and takes this stack as a prerequisite. It should read
`results/04-final.md` §1 (the shipped catalog table) and §7 (what it inherits) before anything else.
Both are written to stand alone.

## What this stack deliberately did not do

Recorded here so a later prompt does not read these as oversights and quietly "fix" them:

- **No rule graduated to default.** RGR-SPEC §2.2's bar is 10 audited true positives; the highest any
  rule reached is 1. The bar was **not** lowered, and `results/02-evidence.md` names which criteria
  were *not* revised so the claim can be checked rather than taken.
- **Nothing was retired.** Eight of the ten rules were judged on a corpus that could not exercise
  them, so a zero is not evidence against them. Retiring one to tidy the catalog is explicitly
  refused by §1.3.
- **Two rule defects were left unrepaired**, because prompt 02 forbade repairing a rule to make it
  pass its own evidence run: FMT009 does not carve out a whole-file *named* namespace though it
  carves out the whole-file *anonymous* section, and lean-fmt's own 34 modules violate FMT008
  seventeen times. Both belong to whoever next owns those rules.
- **CP-3 was never measured.** It is a gap, not a pass. Nothing binds it while no rule reaches
  default, but it should not be cited as satisfied.
- **`ruff-10b` Design B was refused, not deferred again.** The refusal carries a measurement — 33.0×
  against a 1.25× budget, 1 frontend child versus 62 — so a later stack reopening it should argue
  against that number rather than re-derive the question.

## Open items this stack could not close

- **The baseline's single `exact_child` is unexplained.** Not an error path; simply not chased. The
  CP-2 conclusion does not depend on it.
- **CP-4's 0 ms is a measurement without a mechanism.** RGR-SPEC §5.5 predicted ~101 ms and this
  workload showed none. No cause is claimed.
- **Nine graduation conditions are unexercised.** Each names a corpus that would test its rule; none
  of those corpora has been run. Falsifiable and unfalsified is the honest state, and it is not
  evidence that any of the nine is correct. **Full mathlib will not settle them** — it is more of the
  corpus that produced the zeros.
- **The KanProofs structural checkers do not pass on any lean-fmt stack**, including closed and
  verified ones. Repo-wide tooling drift, recorded in `results/01-criteria.md`; adopting or discarding
  the convention belongs with `docs/projects/AGENTS.md`, not with one stack.
