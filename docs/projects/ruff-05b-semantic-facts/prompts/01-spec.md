---
claim_id: RSF-SPEC
status: planned
depends_on: []
---

# Characterize the semantic fact boundary and design the tier twice

## Task

Deliver **RSF-SPEC**: characterize exactly what the frontend `Environment` exposes at the plugin
producer, pin the declared notation/atom spacing fact on fixtures, and design the semantic-fact
representation twice — so `RSF-IMPL` builds a fact whose shape, cache identity, and cost are settled,
not discovered mid-implementation.

Read this stack's `roadmap.md`, its prerequisite stacks' results (`ruff-01`, `ruff-05`), the
`ruff-03` reflow architecture note (`docs/projects/ruff-03-language-formatting/notes/05-reflow-architecture.md`,
the consumer's design), `AGENTS.md`, and the relevant Lean compiler/Lake sources. Confirm first-hand:
`LeanFmt/CompilerPlugin.lean:27` (`getEnv` at the producer), `ModuleArtifact.ofParsedModule` and the
`v3` schema (`LeanFmt/ArtifactModel.lean`), `LeanFmt/LosslessSource.lean` (the syntax projection the
fact sits beside), `Lean/PrettyPrinter/Formatter.lean:357-417` (`pushToken`/`parseToken`, how Lean
derives spacing from the token table), and `Init/Notation.lean:284` / `Init/Prelude.lean:5390`
(`infixl:65 " + "`).

## Target

- Inventory the exact Lean 4.32 APIs that expose declared spacing at the plugin: the token table,
  notation/parser declarations, and the `pushToken` spacing path. Name each API and whether it is
  callable from a `CommandElabM` linter without growing the plugin's import closure.
- Characterize the fact on fixtures: core `_ + _`, a corpus-declared notation (e.g. `«term_≃[_]_»`),
  an atom declaring asymmetric spacing, and an atom declaring none. Record what the fact must carry per
  case.
- **Design the fact representation twice** and write the comparison out (`notes/01-semantic-facts.md`):
  - **A — per-node inline spacing**: each notation node in the artifact carries its resolved inter-atom
    gaps.
  - **B — module-level spacing table**: one table keyed by syntax-kind/token, resolved at consume time.
  - Compare on artifact size growth, cache identity (the fact enters the digest), staleness across a
    toolchain bump, open-set expressibility (a corpus-declared notation must be representable), and
    consumer cost (the printer must map a node to its gaps cheaply).
- Specify: the `Tier.semantic` shape and how `requiredTier`/planning fold it; the `ModuleArtifact` `v3`
  → `v4` bump and its digest impact; and the **demand-gating cost model** — capture runs when a
  semantic rule *or* the formatter needs it, and `format` always does.
- Write `results/01-spec.md` with commands, evidence locators, the chosen representation and why, and
  remaining uncertainty. Update `state/current.md` after reading checks; regenerate `state/next.md`.

## Plan

1. Enumerate the environment/token-table APIs and prove each is reachable at the plugin without a new
   heavy import.
2. Pin the fact on the four fixture cases; record the exact declared spacing each yields.
3. Write designs A and B; compare per the axes above; choose.
4. Specify the tier, schema bump, cache identity, and demand-gating precisely enough to implement.
5. Record open questions and the exact cost the formatter's always-on demand imposes.

## Stop

- This is a specification prompt: it may add characterization fixtures and evidence but ships no tier
  or schema change — that is `RSF-IMPL`.
- No design may hand a live `Environment` downstream; the fact is data.
- A representation that cannot express a corpus-declared notation is rejected.
- Stop rather than specifying a fact that grows the plugin's import closure or weakens cache identity.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and any characterization harness added.
- Run `tests/boundary/run.sh` and confirm no plugin import-closure growth is proposed.
- Use focused fixtures and the frozen sample for scale; complete mathlib is forbidden.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-05b-semantic-facts`.
- Run `git diff --check` and read all output before marking RSF-SPEC verified.
