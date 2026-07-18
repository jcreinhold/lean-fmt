---
claim_id: RYC-SPEC
status: planned
depends_on: []
---

# Freeze the syntax-fix composition interface

## Task

Deliver **RYC-SPEC**: Specify the seam that lets `fix` apply a syntax-tier rule's `.safe` fix by
re-projecting the rendered canonical text, honoring the model `ruff-06`'s RFX-SPEC froze, without
changing `check`, cache identity, or the source-only fast path.

Read `roadmap.md`, `ruff-06-fix-safety/notes/01-model.md` §3 (the frozen composition model),
`ruff-06-fix-safety/results/03-acceptance.md` (the handed-forward adversarial cases), `AGENTS.md`, and
the live fix lifecycle — `LeanFmt/Application.lean` (`renderCanonicalText`, `canonicalAnalysis`, the
fix/publish path), `LeanFmt/Rules.lean` (the FMT010/011/013 `.safe` fixes and their coordinate basis),
and the `ruff-06` transaction/applicability/conflict code — before specifying an interface.

## Target

- Specify the composition behind the existing private intent-to-report architecture; keep CLI
  presentation in `LeanFmt.Cli` and lifecycle/cache/project complexity below callers. Rules gain no
  parser or application-lifecycle authority.
- Name the exact interface: where re-projection happens, what parses the canonical text, which registry
  runs against that projection, and how the resulting canonical-coordinate fixes enter the existing
  applicability/conflict/transaction path. State the gating (only when a selected rule needs it, as
  `requiredTier` already gates projection) and the determinism argument (no fix-then-format vs
  format-then-fix disagreement).
- Design the interface twice — re-project inside canonical rendering vs a separate post-render fix pass
  — and compare caller knowledge, invariants hidden, error surface, exactness, cache identity, critical
  path, and memory enforceability. Justify the choice against `ruff-06`'s rejection of the
  apply-to-original-then-format alternative.
- Enumerate the adversarial cases RYC-FINAL must drive: a fix moving tokens under formatter
  re-projection, UTF-8 boundary edits, multi-edit fixes, syntax-vs-source fix conflict on overlapping
  canonical ranges, and idempotence.
- Write `results/01-spec.md` with the frozen interface, the two designs and the decision, evidence
  locators, and remaining uncertainty. Update `state/current.md` only after reading the checks, then
  regenerate `state/next.md`.

## Plan

1. Reproduce and characterize the current `renderCanonicalText` limit and the `ruff-06` transaction
   seam the composition must reuse.
2. Design the interface twice; compare on the axes above and record the rejected alternative.
3. Specify the smallest deep seam that satisfies the frozen model, reusing the `ruff-06` machinery
   rather than adding a parallel apply path.
4. Name the gating, the determinism guarantee, and the adversarial obligations inherited from
   `ruff-06`.
5. Inspect callers and docs for any claim that composition is already handled or is owned elsewhere.

## Stop

- Do not specify translating original-coordinate edits onto moved canonical bytes; the frozen model is
  re-projection.
- Do not let the applied artifact depend on fix pass order.
- Stop rather than weakening exact semantics, write safety, cache identity, or the resource envelope,
  or giving rules lifecycle authority.

## Check

- This is a specification prompt; its checks are that the interface is complete, sourced against
  `ruff-06`'s frozen model, and buildable in principle against the live seams it names (cite file and
  line for each).
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-10b-syntax-fix-composition`.
- Run `git diff --check` and read all output before marking RYC-SPEC verified.
