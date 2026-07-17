---
claim_id: RLF-NOTATION
status: verified
depends_on: [RLF-FINAL]
---

# Consume the notation-spacing fact to canonicalize operator spacing

## Task

Deliver **RLF-NOTATION**: use the declared notation/atom spacing fact — produced by the
`ruff-05b-semantic-facts` foundation, carried in the `v4` `ModuleArtifact` — to give operators and
notations their canonical *declared* spacing in the printer, so `a+b` becomes `a + b` and a
corpus-declared notation is spaced as it declares. This is the horizontal half of operator formatting;
margin line-breaking is `RLF-REFLOW` (prompt 08).

This prompt does **not** build the fact. The semantic tier, the schema bump, and the
`Environment`-capture producer are `ruff-05b`'s (see `notes/05-reflow-architecture.md` §2, §6). If the
fact is absent or undecodable, the printer keeps its phase-1 conservative bytes for that node. Read
`roadmap.md`, `notes/05-reflow-architecture.md`, `results/02-expressions.md` (why phase 1 could not
supply spacing), the `ruff-05b` results (the fact's shape and guarantees), `AGENTS.md`, and the
relevant Lean compiler sources.

## Target

- In `LeanFmt/Printer.lean`, map a notation node to its declared gaps from the `v4` semantic fact and
  emit them, replacing the phase-1 conservative bytes for notations whose fact is present. The printer
  gains no `Environment` — it reads the immutable fact, nothing more.
- A node with no fact (custom syntax the producer could not resolve, or a `v3` artifact) keeps its
  source bytes: conservative fallback, never invented spacing.
- Add golden fixtures that *change*: `a+b` → `a + b`, an asymmetric-spacing notation, and a
  corpus-declared notation; plus a comment-in-gap case that must be preserved (a notation gap holding a
  comment keeps its bytes, per the phase-1 `respaceable` guard).
- Prove idempotence (`format (format x) = format x`) and parse-preservation (reparse the respaced
  output; same tokens and comments) on the fixtures.
- Write `results/06-notation-facts.md` with commands, measurements, decisions changed, and remaining
  uncertainty. Update `state/current.md` after reading checks; regenerate `state/next.md`.

## Plan

1. Confirm the `ruff-05b` fact is available in the artifact the printer already consumes; locate its
   accessor.
2. Design the node → declared-gaps mapping; where a construct declares tight-left/space-right per gap
   (phase-1 `matchAlt` comma case), honor it exactly rather than spacing every gap.
3. Emit declared spacing for notations with a fact; keep the conservative path for those without.
4. Prove idempotence and parse-preservation on changing fixtures.
5. Inspect callers/docs for a leaked mechanism or a claim stronger than the fixtures show.

## Stop

- The printer must not gain an `Environment` dependency or a frontend import; it consumes the fact.
- Spacing changes only to the *declared* string; a gap with no fact keeps its bytes.
- A gap holding a comment keeps its bytes; no comment is dropped or moved.
- Idempotence is a gate. Stop rather than weakening exact semantics, cache identity, or write safety.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules,
  including `tests/printer/run.sh`.
- Run `tests/boundary/run.sh` and inspect the printer boundary manually; confirm no forbidden import.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden unless this
  prompt is `RCP-ACCEPT` and all prerequisite gates pass.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-03-language-formatting`.
- Run `git diff --check` and read all output before marking RLF-NOTATION verified.
