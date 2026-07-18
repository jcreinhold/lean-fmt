# RYR-SPEC evidence — syntax kinds, linter survey, defect prevalence

All commands were run on `leanprover/lean4:v4.32.0` (this repo's `lean-toolchain`). Two external
corpora are cited by absolute path and pinned commit so a reader can reproduce:

- `~/Code/mathlib4` at `783ccda4ee524f13cc5636237be0a1942bc04824`, `lean-toolchain`
  `leanprover/lean4:v4.32.0` — the version-matched, heavily self-linted corpus.
- `~/Code/PrimeNumberTheoremAnd` — a first-party downstream project that does **not** run Mathlib's
  style linters, used as an *un*-linted control so defect prevalence is not masked by CI enforcement.

The frozen 62-module sample is `experiments/workloads/mathlib-v4.32.0-sample.txt`.

## 1. Syntax kinds — ground truth from the pinned compiler

Every kind a rule keys on is a `leading_parser`/`def` in the compiler this stack pins, cited by file
and line so the catalog names **syntax kinds, not source regexes** (prompt stop rule). Source paths
are under `~/.elan/toolchains/leanprover--lean4---v4.32.0/src/lean/Lean/Parser/`.

| kind (fully-qualified) | declaration | shape (abbreviated) |
| --- | --- | --- |
| `Lean.Parser.Command.moduleDoc` | `Command.lean:60` | `"/-!" >> commentBody >> ppLine` |
| `Lean.Parser.Command.declaration` | `Command.lean:282` | `declModifiers >> (def/theorem/…)` |
| `Lean.Parser.Command.declModifiers` | `Command.lean:114` | `docComment? attributes? visibility? …` |
| `Lean.Parser.Command.«section»` | `Command.lean:299` | `sectionHeader >> "section" >> ident?` |
| `Lean.Parser.Command.«namespace»` | `Command.lean:317` | `"namespace " >> ident` |
| `Lean.Parser.Command.«end»` | `Command.lean:337` | `"end" >> (ppSpace >> ident…)?` |
| `Lean.Parser.Command.«set_option»` | `Command.lean:682` | `"set_option " >> ident >> optionValue` |
| `Lean.Parser.Term.attributes` | `Term.lean:589` | `"@[" >> sepBy1 attrInstance ", " >> "] "` |
| `Lean.Parser.Term.attrInstance` | `Term.lean:587` | `attrKind >> attrParser` |
| `Lean.Parser.Command.derivingClass` | `Command.lean:189` | one class in a `deriving` list |
| `Lean.Parser.Command.optDeriving` | `Command.lean:213` | `("deriving" >> sepBy1 derivingClass ", ")?` |
| `Lean.Parser.Term.paren` | `Term.lean:200` | `"(" >> term >> ")"` — grouping only; `dropParens` (`Term.lean:203`) recurses on `(($stx))` |
| `Lean.Parser.Term.tuple` | `Term.lean:186` | `"(" >> (term ", " sepBy1 term)? >> ")"` — `()`, `(a, b)`; distinct kind from `paren` |
| `Lean.Parser.Term.typeAscription` | `Term.lean:182` | `"(" >> term " :" term? >> ")"` — `(e : T)`; distinct kind from `paren` |

Reproduce:

```sh
BASE=~/.elan/toolchains/leanprover--lean4---v4.32.0/src/lean/Lean/Parser
grep -nE 'def (moduleDoc|declModifiers|«section»|«namespace»|«end»|«set_option»|declaration)' "$BASE/Command.lean"
grep -nE 'def (attrInstance|attributes|paren)' "$BASE/Term.lean"
grep -nE 'def (derivingClass|optDeriving)' "$BASE/Command.lean"
```

These kinds are all present in the projection: `LosslessSource.kinds` interns every node's
`SyntaxNodeKind.toString`, and `nodes`/`tokens` carry the parent/child structure and leaf source text
(`LeanFmt/LosslessSource.lean:180-196`). A `.syntax`-tier rule reads them through `SyntaxFacts`
(`LeanFmt/Rules.lean:79-89`). No rule needs precedence, and the projection carries none — which is
exactly why FMT013 is scoped to the one redundant-paren case that precedence does not decide (§4).

## 2. Existing-linter survey — `~/Code/mathlib4/Mathlib/Tactic/Linter/`

The corpus proves these are real, valued defect classes: Mathlib ships a linter for each and enforces
it in CI. Each row records the option, the tier the *detection* actually needs, and this stack's
disposition.

| Mathlib linter | file:line | detection tier | disposition here |
| --- | --- | --- | --- |
| `linter.style.setOption` | `Style.lean:61` | syntax (matches `set_option` kinds) | **adopt → FMT012** |
| `linter.style.missingEnd` | `Style.lean:142` | syntax¹ | **adopt → FMT009** |
| `linter.style.header` (module-doc clause) | `Header.lean:297` | syntax (`moduleDoc` presence) | **adopt (doc clause only) → FMT008** |
| `linter.globalAttributeIn` | `GlobalAttributeIn.lean:90` | syntax | considered; deferred (§5) |
| `linter.style.cdot` | `Style.lean:191` | syntax | **reject** — token-choice style (§5) |
| `linter.style.dollarSyntax` | `Style.lean:257` | syntax | **reject** — token-choice style (§5) |
| `linter.style.lambdaSyntax` | `Style.lean:300` | syntax | **reject** — token-choice style (§5) |
| `linter.style.longLine` / `longFile` | `Style.lean:425` / `347` | text | **reject** — canonical-formatting / size (§5) |
| `linter.style.emptyLine` | `EmptyLine.lean:79` | text | **reject** — formatter territory (§5) |
| `linter.style.multiGoal` | `Multigoal.lean:50` | syntax | **reject** — proof-style dogma (§5) |
| `linter.haveLet` | `HaveLetLinter.lean:44` | semantic | **reject** — proof-style dogma + elaboration (§5) |
| `linter.oldObtain` | `OldObtain.lean:70` | syntax | **reject** — Mathlib-specific deprecation (§5) |
| `linter.overlappingInstances` | `OverlappingInstances.lean:140` | semantic | **reject** — needs elaboration; out of tier (§5) |
| `linter.privateModule` | `PrivateModule.lean:63` | syntax | considered; deferred (§5) |

¹ `missingEnd` reads elaboration `getScopes` (`Style.lean` body) for convenience, but the open/close
scope stack of one module is **fully determined by its `namespace`/`section`/`end` command
sequence** — a per-file lexical fact — so a syntax-tier count over those node kinds reproduces it. The
detection does not need elaboration; Mathlib merely reused the elaborator's existing stack.

Reproduce:

```sh
cd ~/Code/mathlib4
grep -nE 'register_option linter\.' Mathlib/Tactic/Linter/Style.lean
sed -n '57,190p' Mathlib/Tactic/Linter/Style.lean   # setOption + missingEnd bodies
```

## 3. Defect prevalence — sampled, not assumed

Prevalence was *estimated* with `grep`; the **rules do not detect with `grep`** — they match syntax
kinds (§1). The gap between the two is itself evidence for the syntax tier, recorded per rule.

### FMT012 (development `set_option`)

```sh
grep -rnE 'set_option +(pp|trace|profiler|debug)\.' ~/Code/mathlib4/Mathlib ~/Code/PrimeNumberTheoremAnd \
  | grep -vE ' in$| in '
# mathlib: 22 lines   PrimeNumberTheoremAnd: 272 lines
```

Both counts are **over**-estimates: many hits are the string `"set_option trace.order true"` *inside a
docstring or error message* (e.g. `~/Code/mathlib4/Mathlib/Tactic/Order.lean:285`,
`FastInstance.lean:35`). FMT012 matches the `Lean.Parser.Command.«set_option»` **node**, so a
`set_option` written inside a string literal is not a `set_option` command and never fires — the
syntax tier removes exactly this false-positive class. Genuine committed instances remain (e.g.
`Mathlib/Tactic/Conv.lean:133 set_option pp.notation false`), so the defect is real and the rule has
work to do.

### FMT010 / FMT011 (duplicate attribute / deriving class)

```sh
grep -rnE '@\[[^]]*\b([a-zA-Z_]+)\b[^]]*, *\1\b' ~/Code/mathlib4/Mathlib ~/Code/PrimeNumberTheoremAnd | wc -l   # 0
grep -rnE 'deriving [^,]*\b([A-Z][a-zA-Z]*)\b.*, *\1\b'  ~/Code/mathlib4/Mathlib ~/Code/PrimeNumberTheoremAnd     # (none)
```

Near-zero in these two corpora. This is expected and is **not** a reason to drop the rules: an exact
in-list duplicate is a mechanical editing slip (copy-paste, merge conflict) that surfaces in
first-party, pre-CI code — the state `lean-fmt` runs in — and both rules carry a **safe** fix with no
false-positive tail (an exact textual duplicate is unambiguous). They are cheap, correct, and silent
on clean code. Their low corpus prevalence is recorded honestly rather than inflated.

### FMT013 (redundant nested parentheses)

```sh
grep -rncE '\(\(' ~/Code/PrimeNumberTheoremAnd   # 33209 lines contain "(("
```

This number is meaningless as a defect count: almost every `((` is a function application inside a
paren (`f (g x)` → `(f (x))`), a tuple, or a type ascription — **not** a `paren` node directly
containing a `paren` node. `grep` cannot see tree structure; the rule reads it. FMT013 fires only on
the tree shape `Term.paren ▸ Term.paren` with no other child, which precedence does not decide, so it
is exact where `grep` is hopeless. Precisely because the flat count is uninformative, FMT013 ships
**preview** until RYR-FINAL measures its true tree-shape rate on the frozen sample.

## 4. Baseline gates (docs-only prompt — no code changed)

```
LEAN_NUM_THREADS=1 lake build                         → exit 0
tests/boundary/run.sh                                 → (see results/01-catalog.md)
check_stack.py docs/projects/ruff-10-syntax-rules --structural  → OK: 3 prompt(s), 0 warning(s)
write_next.py docs/projects/ruff-10-syntax-rules --check        → OK: matches first_unresolved
git diff --check                                      → clean
```
