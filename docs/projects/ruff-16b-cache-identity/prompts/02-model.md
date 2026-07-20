---
claim_id: RCI-MODEL
status: verified
depends_on: [RCI-SPEC]
---

# Model cache currency and prove the decision sound and complete

## Task

Deliver **RCI-MODEL**: Express the currency decision frozen by `RCI-SPEC` as a pure function over an
explicit observation, specify what a correct answer is independently of that function, and prove
soundness **and** completeness under hypotheses that name every unprovable step.

Read `roadmap.md`, `notes/01-what-is-provable.md`, its prerequisite stack results, `AGENTS.md`, the
current implementation and tests, and the relevant Lean compiler/Lake sources before changing an
interface. Write interface comments and characterization tests before implementation where the behavior
is not already frozen.

## Target

- Ship `LeanFmt/Cache/Spec.lean`: the pure model, the four lemmas, and the theorem pair. Do **not** ship
  a top-level `Proofs.lean`; the model lives next to what it specifies.
- Give proof modules their own `lean_lib` and glob it explicitly. They must not enter
  `LeanFmtCompilerPlugin` or the shipped binary's link closure — `CLAUDE.md` records that Lake links
  every module a library globs, imported or not.
- Write `results/02-model.md` with exact commands, the theorem statements as they landed, which
  hypotheses each depends on, decisions changed during execution, and remaining uncertainty.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Define `Spec.analyze : Grammar → Source → Analysis` as the specification of what a run should
   compute. Defining it as "whatever the cache returns" makes every theorem below vacuous; state in the
   module comment why it is not defined that way.
2. Define `Obs` as exactly what the cache can observe without running the frontend, and `serves` as a
   pure function of it. This refactor is worth doing on its own merits — it is also what makes the
   decision testable — but it must not change the shipped decision, which `RCI-SPEC` froze.
3. Prove `source_current`, `grammar_current`, `tier_adequate`, `schema_current`, each stated for its
   caller rather than for the tactic that closes it.
4. Assemble `serves_sound`. Then prove `serves_complete`: an entry genuinely built from the current
   world is served. **Soundness alone is satisfied by a `serves` that always returns `false`** — both
   directions, or the result is worthless.
5. Carry A1–A4 as explicit hypotheses. Record, per theorem, which it uses.
6. Review `Spec.analyze` against intent by reading it. A closed goal shows the term type-checks, not
   that the specification says the right thing; that review is a deliverable of this prompt.

## Stop

- **No `axiom` declarations, no `sorry`, no `native_decide`.** Unprovable steps are theorem hypotheses,
  so they appear in the type of everything downstream. An assumption that disappears from use sites has
  defeated the purpose of stating it.
- **Do not weaken the specification to close a goal.** If `grammar_current` will not go through, the
  candidate decision is wrong and `RCI-SPEC` reopens — that is the mechanism working, not an obstacle.
  §6 of the note records this already happening once.
- Do not let the proof drive the shipped decision toward something easier to verify but weaker in
  practice; the acceptance measurements in `RCI-FINAL` still bind.
- Do not introduce proof dependencies into the plugin or the binary's link closure.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and confirm the proof library builds without `sorry` warnings.
- Run `#print axioms` on each top-level theorem and record the output verbatim in the result note; the
  expected set is Lean's own (`propext`, `Classical.choice`, `Quot.sound`) and nothing else.
- Run `tests/boundary/run.sh` and confirm the proof library is absent from the plugin and binary link
  closures.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-16b-cache-identity`.
- Run `git diff --check` and read all output before marking RCI-MODEL verified.
