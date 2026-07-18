# 01-catalog — RYR-SPEC result

**Claim:** RYR-SPEC — inventory compiler syntax kinds and existing Lean/mathlib linters, sample real
defects, and specify ≥6 stable-or-preview syntax rules with codes, examples, exclusions, and fix
safety.

**Status:** delivered. Docs-only prompt — no production module, fixture, or test changed. The catalog
is `notes/01-catalog.md`; the reproducible evidence is `evidence/01-catalog.md`.

## What was produced

- `notes/01-catalog.md` — the frozen catalog: six syntax-tier rules **FMT008–FMT013** across the four
  roadmap families (module documentation → FMT008; namespace/module consistency → FMT009; duplicate
  attributes/modifiers → FMT010, FMT011; mechanically redundant syntax → FMT012, FMT013), each with
  fires-when, exact syntax kinds, exclusions, default/preview state, and fix safety; a rejected-
  candidates section; and the explicit list of what RYR-IMPL owes (§5), led by the first-syntax-tier
  wiring.
- `evidence/01-catalog.md` — §1 syntax kinds cited to the pinned v4.32.0 compiler; §2 the Mathlib
  linter survey with per-linter tier and disposition; §3 defect prevalence scans; §4 baseline gates.

## Rules at a glance

| code | family | default | fix | applicability |
| --- | --- | --- | --- | --- |
| FMT008 module docstring required | docs | preview | — | report-only |
| FMT009 unclosed section/namespace | structure | enabled | — | report-only |
| FMT010 duplicate attribute in a list | redundancy | enabled | delete dup | `.safe` |
| FMT011 duplicate deriving class | redundancy | enabled | delete dup | `.safe` |
| FMT012 development-only `set_option` | debug | enabled | — | report-only |
| FMT013 redundant nested parentheses | redundancy | preview | drop outer | `.safe` |

## Commands run (exact)

```sh
# Ground-truth syntax kinds (not regexes) — pinned compiler source
BASE=~/.elan/toolchains/leanprover--lean4---v4.32.0/src/lean/Lean/Parser
grep -nE 'def (moduleDoc|declModifiers|«section»|«namespace»|«end»|«set_option»|declaration)' "$BASE/Command.lean"
grep -nE 'def (attrInstance|attributes|paren|tuple|typeAscription|dropParens)' "$BASE/Term.lean"
grep -nE 'def (derivingClass|derivingClasses|optDeriving|optDefDeriving)' "$BASE/Command.lean"

# Existing-linter survey — version-matched mathlib (commit 783ccda4…)
cd ~/Code/mathlib4 && grep -nE 'register_option linter\.' Mathlib/Tactic/Linter/Style.lean
sed -n '57,190p' Mathlib/Tactic/Linter/Style.lean

# Defect prevalence — mathlib (self-linted) vs PrimeNumberTheoremAnd (un-linted control)
grep -rnE 'set_option +(pp|trace|profiler|debug)\.' ~/Code/mathlib4/Mathlib ~/Code/PrimeNumberTheoremAnd | grep -vE ' in$| in '
grep -rnE '@\[[^]]*\b([a-zA-Z_]+)\b[^]]*, *\1\b' ~/Code/mathlib4/Mathlib ~/Code/PrimeNumberTheoremAnd | wc -l

# Baseline gates
LEAN_NUM_THREADS=1 lake build
tests/boundary/run.sh
python check_stack.py docs/projects/ruff-10-syntax-rules --structural
python write_next.py docs/projects/ruff-10-syntax-rules --check
git diff --check
```

## Checks read

| check | result |
| --- | --- |
| `LEAN_NUM_THREADS=1 lake build` | exit 0 (no code changed) |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `check_stack.py … --structural` | `OK: 3 prompt(s), 0 warning(s), no errors` |
| `write_next.py … --check` | `OK: state/next.md matches first_unresolved='01-catalog'` (pre-edit baseline; regenerated after state update) |
| `git diff --check` | clean (docs only; verified before commit) |

Baseline build and boundary were run on the unmodified tree to establish that a docs-only prompt broke
nothing and to pin the green baseline RYR-IMPL starts from.

## Key measurements / evidence

- **Syntax tier beats regex, quantified.** The `set_option` prevalence grep over-counts because it
  matches the *string* `"set_option trace…"` inside docstrings (e.g.
  `~/Code/mathlib4/Mathlib/Tactic/Order.lean:285`); FMT012 matches the `«set_option»` **node** and so
  ignores those. The `((` grep returns 33 209 PrimeNumberTheoremAnd lines, almost none of which are the
  `paren ▸ paren` tree FMT013 needs. Both are recorded as the case for `.syntax`, not incidental.
- **`missingEnd` is syntax-tier despite reading `getScopes`.** The scope stack is a per-file lexical
  fact fully determined by the `namespace`/`section`/`end` command sequence, so FMT009 recomputes it
  from node kinds without the elaborator (evidence §2 note ¹).
- **Exclusions are structural, not heuristic.** `(e : T)` / `(a, b)` / `()` are the distinct kinds
  `typeAscription` / `tuple`, never `paren`, so FMT013 cannot false-fire on them by construction.
  `private private` is a `declModifiers` parse error, so it never reaches accepted source — no rule
  needed (same "acceptance owns it" argument as `ruff-08` §2).

## Decisions changed during execution

1. **FMT009 and FMT012 demoted from safe-fix to report-only.** Appending `end Foo` or deleting a
   committed `set_option` is author judgment a formatter can get wrong; naming the defect is the honest
   half. (`notes/01-catalog.md` §6.)
2. **FMT013 kept but shipped preview.** Nearly cut after the noisy `grep`, kept because the tree-shape
   rule is exact where `grep` is not; preview until RYR-FINAL measures its real rate on the frozen
   sample.
3. **`globalAttributeIn` and `privateModule` deferred, not rejected.** Six rules already cover the four
   families; the first syntax-tier stack is the wrong place to maximize rule count against unproven
   wiring.

## Remaining uncertainty (handed to RYR-IMPL / RYR-FINAL)

- **The first-syntax-tier wiring is the real work.** `Application.renderCanonicalText` and
  `availableAnalysis`'s source-only shortcut assume every rule is `.source`
  (`docs/adding-a-rule.md:138-142`, pinned by `testEngineTiers`). RYR-IMPL must fetch the projection
  when a selected rule demands `.syntax` and update that assumption. This is scoped in
  `notes/01-catalog.md` §5 as owed, not open — the projection already carries everything the six rules
  read (`LosslessSource` §1), so the risk is integration, not feasibility.
- **FMT009 name-stack matching** (`end Foo.Bar` popping `namespace Foo`/`namespace Bar`) needs a
  concrete algorithm in RYR-IMPL; the catalog fixes the semantics, not the code.
- **FMT013's true prevalence** is unknown until a tree walk runs on the frozen sample (RYR-FINAL); its
  preview default is contingent on that number.
- **`set_option … in` term/tactic forms** are in scope for FMT012 but the standalone command is the
  primary target; RYR-IMPL decides whether to cover the `in` forms in v1 or defer.
