# The syntax-rule catalog

`RYR-SPEC`. This freezes which **syntax-tier** rules `lean-fmt` ships — rules that read the exact
frontend's projection (`SyntaxFacts`: node kinds, parent/child structure, and leaf source text) rather
than raw bytes. It changes no product behavior; `RYR-IMPL` implements the accepted rules against this
note. Every kind named here is cited to the pinned compiler in `evidence/01-catalog.md` §1, every
adopted rule to a real Mathlib linter in §2, and every prevalence claim to a reproducible scan in §3.

These are the product's **first** `.syntax`-tier rules. Until now every shipped rule is `.source`
(`LeanFmt/Rules.lean:283-324`), and two production sites say so in their own docstrings —
`Application.renderCanonicalText` and the source-only shortcut in `availableAnalysis`, pinned by
`testEngineTiers` (`docs/adding-a-rule.md:138-142`). That wiring — not the rule bodies — is the bulk
of `RYR-IMPL`'s work, and this note names it as owed so the impl prompt does not discover it late.

## 1. The one fact that decides tier

A `.source` rule sees the normalized byte string and nothing else. It cannot tell `@[simp, simp]` (a
duplicate attribute) from the same bytes inside a string literal, cannot find where a `set_option`
command ends, and cannot know a `(` opens a `Term.paren` rather than a tuple or a notation. Every rule
below needs the parse: **which bytes are which kind of node, and how they nest.** That is the
definition of the `.syntax` tier (`AGENTS.md`: "Syntax-tier rules need the compiler artifact or the
exact frontend"), and it is why none of these can be an `.source` rule the way `ruff-08`'s byte scans
are. The projection carries the parse losslessly and carries **no precedence** (the parser already
resolved it into the tree — `ruff-03` term-census); a rule that would need precedence is not shippable
here, which is a real constraint FMT013 is designed around (§4).

The projection also excludes the module header (`headerStop`) and the terminal command
(`terminalStop`), and a `choice` node keeps only its first alternative
(`LosslessSource.lean:185-192, 300-306`). No rule below reads the header or a terminal, and none walks
`choice` alternatives, so these exclusions cost them nothing — but RYR-FINAL must test a file whose
only candidate node sits in the tail or under a `choice`, and confirm silence.

## 2. What ships: six syntax-tier rules

Codes continue the `FMT0xx` namespace. Taken: `FMT001`–`FMT004` (engine, `Rules.lean:283`),
`FMT005`–`FMT007` (imports, `Rules.lean:383`), `FMT900` (suppression). **`FMT008`–`FMT013` are free**;
no clash. Every finding's range is a half-open UTF-8 byte range into the normalized source, the one
coordinate system the projection, findings, and digests already share (`AGENTS.md`; `Rules.lean:57-66`).

The four roadmap families map to the six rules as: **module documentation** → FMT008; **namespace/
module consistency** → FMT009; **duplicate attributes/modifiers** → FMT010, FMT011; **mechanically
redundant syntax** → FMT012, FMT013.

### FMT008 — module lacks a module docstring

- **Fires when:** the module contains at least one `Lean.Parser.Command.declaration` node but **no**
  `Lean.Parser.Command.moduleDoc` (`/-! … -/`) node.
- **Kinds:** `moduleDoc` (Command.lean:60), `declaration` (Command.lean:282).
- **Category:** `docs`. **Default:** **preview**. **Fixable:** no (report-only).
- **Why report-only:** the fix would be to *write documentation*, which no formatter can synthesize.
  Emitting a placeholder `/-! -/` is worse than nothing — it launders "undocumented" into "documented
  with an empty doc." So there is no honest edit; the rule names the gap and stops.
- **Why preview:** mandatory module docs are a genuine, non-proof-style documentation policy (Mathlib
  enforces it via `linter.style.header`), but it is a *project* policy — a script directory or a
  generated file legitimately has none. Preview keeps it opt-in until a project asks for it, matching
  the roadmap's "documentation … while … avoiding proof-style dogma."
- **Range:** the first declaration's node range (the thing that should have been preceded by a doc),
  zero-width would hide the finding; a real span points the user at what is undocumented.
- **Exclusions:** a module with only imports/`open`/`section` and **no** declaration (a re-export or
  config module) has no `declaration` node → not flagged. A declaration-level `/-- … -/` (`docComment`
  inside `declModifiers`, Command.lean:114) is **not** a module doc and does not satisfy the rule — the
  kinds are distinct, so this exclusion is structural, not heuristic.

### FMT009 — unclosed `section` or `namespace`

- **Fires when:** at the terminal, the module's `namespace`/`section` opens outnumber their matched
  `end` closes — i.e. a scope is left open at end of file.
- **Kinds:** `«namespace»` (Command.lean:317), `«section»` (Command.lean:299), `«end»`
  (Command.lean:337). Matching is a name stack: `namespace Foo` pushes `Foo`; `section` pushes an
  anonymous scope; `section Bar` pushes `Bar`; `end` pops one anonymous scope; `end Foo` pops scopes
  whose concatenated names spell `Foo`. Leftover pushes at the terminal are the finding. This is the
  same stack Mathlib's `linter.style.missingEnd` reads from the elaborator; here it is recomputed from
  node kinds, which is sound because the stack is a per-file lexical fact (evidence §2, note ¹).
- **Category:** `structure`. **Default:** **preview** (§3). **Fixable:** no (report-only) for now.
- **Why report-only, not a fix:** appending `end Foo` at EOF is *usually* meaning-preserving, but the
  correct insertion point and name is exactly the judgment the author elided; a formatter guessing it
  can mask a genuine structural mistake (a scope meant to close earlier). Naming the open scope is the
  honest, low-risk half. A safe fix is a candidate for a later revision once RYR-FINAL measures the
  false-open rate.
- **Exclusion (mirrors Mathlib):** an outermost `noncomputable`/`meta`/`public section` left open —
  the idiomatic "whole-file section" — is **not** flagged. Detected from the `section` node's leading
  modifier tokens (`sectionHeader`, Command.lean:299). RYR-FINAL tests this exclusion explicitly.
- **Range:** the unclosed opener's node range.

### FMT010 — duplicate attribute in one attribute list

- **Fires when:** one `Lean.Parser.Term.attributes` node (`@[ … ]`) has two `attrInstance` children
  with **byte-identical** normalized source text.
- **Kinds:** `attributes` (Term.lean:589), `attrInstance` (Term.lean:587).
- **Category:** `redundancy`. **Default:** **preview** (§3). **Fixable:** yes, **`.safe`**.
- **Why the fix is safe:** attribute application is idempotent for an exact-duplicate instance —
  applying `simp` twice in one list is applying it once — so deleting the later duplicate (and its
  `", "` separator) removes text without changing what the elaborator records. "Safe" here is a claim
  under this rule's evidence (the two instances are textually identical), tied to the tier, per
  `docs/adding-a-rule.md:75-88`; it is **not** "it reparses."
- **Exclusions (the false-positive guard is exactness):** attributes are compared as text, so
  `@[simp, simp ↓]` (different arguments) is **not** a duplicate; `@[local simp, simp]` (different
  `attrKind`) is **not** a duplicate; only whitespace-insensitive exact repeats fire. Duplicates
  across *two separate* `@[…] @[…]` blocks are **not** in scope — merging blocks is a formatting
  decision, not a redundancy this rule owns. Comparison is within one `attributes` node only.
- **Range:** the duplicate `attrInstance`'s span (the text the fix deletes).

### FMT011 — duplicate `deriving` class

- **Fires when:** one `optDeriving` clause lists the same `derivingClass` twice, e.g.
  `deriving Repr, Repr`.
- **Kinds:** two `derivingClass` (Command.lean:189) siblings under one `derivingClasses`
  (`sepBy1 derivingClass ", "`, Command.lean:191), which appears in both deriving wrappers —
  `optDeriving` (inductive/structure, Command.lean:213) and `optDefDeriving` (`def`, Command.lean:206);
  the rule keys on the `derivingClass` siblings, so it covers either wrapper.
- **Category:** `redundancy`. **Default:** **preview** (§3). **Fixable:** yes, **`.safe`** — deriving the same
  instance twice derives it once; deleting the later duplicate (and its `", "`) is meaning-preserving
  by the same idempotence argument as FMT010.
- **Exclusions:** exact textual match only; `deriving DecidableEq, Repr` is not a duplicate. A class
  with arguments compares by full text.
- **Range:** the duplicate `derivingClass`'s span. Sibling of FMT010; the two together are the
  roadmap's "duplicate attributes/modifiers" family. (`private private`-style modifier duplicates are
  **not** a rule: `declModifiers` admits each visibility/modifier at most once, so a repeat is a parse
  error and never reaches accepted source — the same "acceptance owns it" argument `ruff-08` §2 used.)

### FMT012 — development-only `set_option`

- **Fires when:** a `Lean.Parser.Command.«set_option»` sets an option whose name root is `debug`,
  `pp`, `profiler`, or `trace` (the exact set of `linter.style.setOption`, Style.lean body).
- **Kinds:** `«set_option»` (Command.lean:682); the option name is the `ident` leaf under it. The
  `set_option … in` term/tactic forms are also detectable and in scope; the standalone command is the
  common case and the primary target.
- **Category:** `debug`. **Default:** **preview** (§3). **Fixable:** no (report-only).
- **Why report-only, not a delete fix:** although `pp`/`trace`/`profiler`/`debug` options do not
  change *elaboration results*, deleting a committed `set_option` is an intent decision (the author may
  be mid-debugging), and — for the `… in` forms — the boundary of what the `in` scopes is not something
  a byte-safe argument settles. `lean-fmt` names the leftover; the human removes it. This matches the
  roadmap's "unsafe … simplifications … are preview or display-only," taken conservatively as
  report-only.
- **Exclusions:** any option outside the four roots (e.g. `set_option maxHeartbeats`, a legitimate
  proof-scaling knob) is **not** flagged — narrowing to the debug set is what keeps this off production
  proofs. Because it matches the `set_option` **node**, a `set_option` written inside a string or
  comment never fires (evidence §3), which a regex cannot promise.
- **Range:** the `set_option` head token through the option name.

### FMT013 — redundant nested parentheses

- **Fires when:** a `Lean.Parser.Term.paren` node's single meaningful child is itself a
  `Lean.Parser.Term.paren` — i.e. `((e))`, where the outer pair wraps nothing but an already-complete
  parenthesized term.
- **Kinds:** `paren` (Term.lean:200, `hygienicLParen >> ppDedentIfGrouped termParser >> ")"` — one
  term child, no other production shares its shape). Compiler precedent: Lean's own `dropParens`
  (Term.lean:203) recurses on exactly `` `(($stx)) `` — a `paren` wrapping a `paren` — which is this
  rule's tree shape, confirmed against the grammar rather than assumed.
- **Category:** `redundancy`. **Default:** **preview**. **Fixable:** yes, **`.safe`** — the inner
  `(e)` is a complete atomic term in every context, so removing the outer pair cannot change how the
  result groups; no precedence is consulted (and the projection carries none).
- **Why only the nested case:** general redundant-paren removal (`(x)` where `x` needs no parens) is
  a precedence question, and the projection deliberately does not carry precedence (§1). The
  `paren ▸ paren` shape is the one redundant-paren case precedence does **not** decide, so it is the
  only one this tier can answer honestly. This limit is the point, not a shortcoming.
- **Exclusions are structural, by distinct kind, not heuristic:** `()` and `(a, b)` are
  `Lean.Parser.Term.tuple` (Term.lean:186), `(e : T)` is `Lean.Parser.Term.typeAscription`
  (Term.lean:182), `⟨…⟩` is `anonymousCtor` — none is a `paren`, so none can be the inner child that
  fires FMT013. `(· + 1)` is a `paren` but its child is a cdot term, not a `paren`, so it does not
  fire either. Only `paren` directly wrapping `paren` matches, and `paren`'s single-term grammar makes
  "single child" exact.
- **Why preview:** `grep` cannot estimate its true rate (evidence §3 — 33k flat `((` lines, almost all
  irrelevant); only a tree walk can, and RYR-FINAL runs it on the frozen sample. Preview until that
  number exists.

## 3. Applicability summary

| code | category | default | fix | applicability |
| --- | --- | --- | --- | --- |
| FMT008 | docs | preview | — | report-only |
| FMT009 | structure | preview | — | report-only |
| FMT010 | redundancy | preview | delete duplicate | `.safe` |
| FMT011 | redundancy | preview | delete duplicate | `.safe` |
| FMT012 | debug | preview | — | report-only |
| FMT013 | redundancy | preview | drop outer pair | `.safe` |

Four report-only, two `.safe`-fix. No `.unsafe` or `.displayOnly` fix ships: a rule either has a
meaning-preserving edit under its own evidence or it emits none, following `ruff-08`'s discipline
("When there is no meaning-preserving edit, emit no fix rather than an `.unsafe` one nobody should
apply", `docs/adding-a-rule.md:60-68`).

**All six ship as `preview` (default-off), and that is a scaffold correction made during RYR-IMPL, not
the freeze's original intent.** The freeze had FMT009–FMT012 `enabled`. Implementing that exposed two
facts. (1) `defaultEnabled` was never enforced by selection — the default selection was literally
`"all"`, so before ruff-10 (every rule default-on) it was moot, and FMT008/FMT013, already frozen
`preview`, were in fact *running* by default. Enforcing the field (a `default` selector that expands to
`defaultEnabled` rules) is the minimal fix ruff-10 needs for its own preview rules. (2) A default-on
*syntax*-tier rule makes the default `check`/`format` run demand the projection for **every** file —
retiring the measured source-only fast path (`ruff-05`) for the common case, and forcing non-module
files (lakefiles, standalone scripts) onto the exact frontend, where they cost a full frontend run or
fail with no analyzer. That is real work the scaffold already owns elsewhere: promoting a preview rule
into the default set is **`ruff-12-rule-lifecycle`** ("experimental rules require preview";
lifecycle-aware selection), the edit-loop/incremental cache is **`ruff-16`**, and the default-run cost
budget is **`ruff-19`**. ruff-10's own roadmap says "at least six **stable or preview** rules" — preview
is in scope; graduating to stable/default is not. So ruff-10 ships all six as preview, fully
implemented and selectable (`--select <code>` / `<category>` / `all`), and ruff-12 graduates the stable
ones once the lifecycle machinery and the ruff-16/ruff-19 support exist. The cache **tier tag**
(`SemanticResult.tier`, `cacheHitServes`) that this stack added stays load-bearing regardless: any
explicit `--select FMT010` still demands `.syntax`, and the tier gate is what stops a source-only
shortcut entry from serving it a false negative.

## 4. What is rejected, and why (survey in evidence §2)

- **`cdot` / `dollarSyntax` / `lambdaSyntax`** (`·` vs `.`, `<|` vs `$`, `fun` vs `λ`) — token-choice
  *style*. These are either canonical-formatter policy (the formatter can pick one spelling) or pure
  preference; shipping them as default lint is "canonical formatter policy as default lint noise,"
  which the roadmap forbids. Rejected.
- **`longLine` / `longFile` / `emptyLine`** — line width, file size, blank-line runs. Width and blank
  runs are canonical-formatting territory; file size is a project budget, not a syntax defect.
  Rejected as formatter/size, not lint.
- **`multiGoal` / `haveLet`** — proof-writing preferences ("one goal per focus," "`have` vs `let`").
  These are exactly the "personal proof style" the prompt stop rule rejects, and `haveLet`
  additionally needs elaboration (a type) it cannot get at the syntax tier. Rejected.
- **`oldObtain`** — flags a *deprecated* Mathlib spelling. Deprecation is Mathlib-version policy, not a
  general syntax defect, and would fire on code that is correct outside Mathlib. Rejected.
- **`overlappingInstances`** — needs the elaborator to know two instances overlap. That is the
  `.semantic` tier, which does not exist yet and whose first rule arrives with its own producer and
  test (`Rules.lean:26-34`, `ruff-11`). Out of scope for a syntax stack. Rejected here, noted for
  `ruff-11`.
- **`globalAttributeIn`** (`attribute [instance] foo in …` — the attribute is global despite the
  `in`) and **`privateModule`** (a module of only private declarations) — both are honest, syntax-tier,
  and genuinely useful. They are **deferred, not rejected**: six rules already cover all four required
  families with room to spare, and adding more surface to the product's first syntax-tier stack widens
  the RYR-FINAL differential without deepening family coverage. Recorded here as the obvious next
  additions once the tier's wiring is proven.
- **General redundant parentheses** — needs precedence the projection does not carry (§1). Only the
  nested case (FMT013) is answerable. Rejected as a general rule; kept in its answerable form.

## 5. What RYR-IMPL owes (roadmap completion contract)

1. **The first-syntax-tier wiring**, not just rule bodies: teach `Application.renderCanonicalText` and
   `availableAnalysis`'s source-only shortcut that a selected rule may demand `.syntax`, fetch the
   projection (a current `.olean` + its facet, or the exact frontend) when it does, and update
   `testEngineTiers`'s pinned assumption. This is the deep half; the rule functions are the shallow
   half.
2. **Per rule:** positive fixtures (each defect), negative (clean file; the near-miss that must stay
   silent — `@[simp, simp ↓]`, `set_option maxHeartbeats`, an outermost `noncomputable section`,
   `deriving A, B`), custom-syntax (a notation reusing `(` or `@[`, preserved and ignored), quotation/
   generated syntax (a defect *inside* a `` `(…) `` quotation must not fire — it is data, not code),
   comment/string (a `set_option`-looking string stays silent), malformed (a rejected file is not
   silently linted), and the projection edge cases from §1 (tail, `choice`).
3. **Fix tests** for FMT010/FMT011/FMT013 through `preparePatch` (safe applicability, exact byte
   ranges including the `", "` separator, conflict provenance), plus a `--unsafe-fixes` case only if
   any fix is later demoted to `.unsafe`.
4. **Registry + selection + suppression + `rules` command** uniformity: the six codes must select by
   category, suppress like any code, and print in `lean-fmt rules` with their derived `input` tier —
   the same discipline `ruff-08`/`ruff-09` proved.
5. **`docs/adding-a-rule.md`** refresh: it currently says every shipped rule is `.source`; after
   RYR-IMPL that is false, and the "first `.syntax`-tier rule" caveat becomes a description of shipped
   code.

## 6. Decisions changed while freezing this

- **Six rules, four report-only.** An earlier draft made FMT009/FMT012 safe-fix rules. Rejected:
  appending `end Foo` or deleting a `set_option` is a judgment the author elided, and a formatter that
  guesses it can mask a real mistake. The honest half is naming the defect; the fix waits for
  RYR-FINAL's false-positive numbers. Only exact-duplicate deletion (FMT010/FMT011) and the
  precedence-free nested-paren drop (FMT013) are safe under a byte/idempotence argument.
- **FMT013 kept but demoted to preview.** It was nearly cut as makeweight after the `grep` scan
  returned noise (evidence §3). Kept because the *tree-shape* rule is exact where `grep` is hopeless —
  which is the whole case for the syntax tier — but shipped preview until its real rate is measured.
- **`globalAttributeIn`/`privateModule` deferred, not adopted.** Both are good syntax-tier rules; the
  stack does not need them to satisfy the contract, and the first syntax-tier stack is the wrong place
  to maximize rule count. Deferring them keeps RYR-FINAL's differential proportional to the wiring
  risk it is actually validating.
