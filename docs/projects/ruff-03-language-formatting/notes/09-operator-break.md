# RLF-OPERATOR-BREAK — extending the β-break to operators, binders, and match arms

`RLF-REFLOW` shipped one breakable kind — `Lean.Parser.Term.app` — and deferred operators, bracketed
binders, and `matchAlt` to this prompt (`notes/07-reflow-policy.md` §2; `reflows` in `Printer.lean` is a
one-line `kind == "Lean.Parser.Term.app"`). This note establishes, first-hand, where a break in each of
those three kinds is parse-legal, then designs the break policy twice and records the choice — written
*before* the implementation so the comparison is on the record, not reconstructed after the code.

The engine and the safety envelope are unchanged from `notes/07`: the printer is align-free
(`Doc.lean` has no `align`/`pushAlign`, §1.3), so every break is *break-before-the-construct's-tail*
with a fixed `nest` from the command root, and every break fires only inside a single-line, over-margin
command (`Tree.mayCollapse`) whose gaps are pure-space with a declared separator (the `clean` guard).
What this prompt adds is (a) *which kinds* may break and (b) *which gaps within a kind* are the break
points — because, unlike `app`, the break point is no longer "every gap after the head."

## 1. Where the break is legal (Plan step 1)

All three facts were confirmed by fresh-frontend reparse: format the flat construct by hand into the
candidate broken shape, `__analyze-exact` both, and compare token stream **and** parse tree with
`experiments/compare_tokens.py` (the `RLF-ACCEPT` tree gate). "PARSE-PRESERVING" below means both the
token stream and the `(kind, parent)` tree are identical to the flat input's.

### 1.1 Operators / notations — the freest kind, no column check on operands

`a + b` is the node `«term_+_»`, whose parts are `[child(left), token("+"), child(right)]` (confirmed by
dumping the artifact of `def x : Nat := 111111 + 222222 + 333333`: node 17 `«term_+_»` owns the second
`+` token and has children node 18 `«term_+_»` and node 21 `num`). A left-associative chain
`a + b + c` is `((a + b) + c)`: the outer node's head is the inner `«term_+_»`, so the recursion lives in
the *head*, which the engine never nests — every level of a chain therefore breaks at the **same** column,
not a staircase.

The operator's operands carry **no column check**. `infixl:65 " + " => HAdd.hAdd` expands to
`syntax:65 term:65 " + " term:66 : term` — the operands are `termParser` at a precedence, with no
`checkColGt`/`checkColGe`/`checkColEq` (contrast `app`'s `argument := checkWsBefore >> checkColGt >> …`,
`Lean/Parser/Term.lean:885-892`). Empirically this is why *all three* candidate break shapes reparse
identically, continuation landing at column 2 well *left* of the operands at column 15:

| shape | rendered | reparse |
| --- | --- | --- |
| `op_trail` — operator ends the line | `111111 + 222222 +`↵`  333333` | PARSE-PRESERVING |
| `op_lead` — operator starts the continuation | `111111 + 222222`↵`  + 333333` | PARSE-PRESERVING |
| `op_appstyle` — operator alone on its own line | `111111 + 222222`↵`  +`↵`  333333` | PARSE-PRESERVING |

So for operators the break policy is a pure *style* choice, not a safety one: the parse is preserved
whatever we pick. (For `app`, by contrast, `notes/07` §1 had to *earn* the one legal shape against a live
`checkColGt`.)

Operator/notation kinds cannot be enumerated — `«term_+_»`, `«term_*_»`, `«term_∧_»`, and every
user-declared mixfix are distinct kinds. But they are exactly the nodes the `ruff-05b` declared-spacing
fact covers: `Tree.nodeSpacing` returns `.declared seps` for precisely these. So the gate that reaches
them generically is "the fact declared this node's spacing," not a kind list (see §3).

### 1.2 Bracketed binders — reachable through `optDeclSig`, not their own container

The binders of `def f (aaaaaa : Nat) (bbbbbb : Nat) (cccccc : Nat) : Nat` are three `explicitBinder`
nodes (14, 18, 22) whose parent is an **anonymous `null`** node (13) — not a kind we can match on
without matching every `null` in the tree. But their grandparent `optDeclSig` (node 12) *is* a stable
kind, and `Tree.liftedParts` lifts one level of `null` (`Printer.lean:873-882`): `liftedParts(optDeclSig)`
flattens the binder-group `null` and the return-type `null` into a single parts list
`[explicitBinder, explicitBinder, explicitBinder, typeSpec]`. So the binders become the break points of
`optDeclSig` (equally `declSig`, the required-signature form) without ever naming the `null`.

Breaking before each binder reparses. As built, the β-mechanism's uniform `nest 2` hangs every part
after the head one indent below the head, and the return-type `typeSpec` is itself a lifted part, so it
lands on its own line at the same column:

    def f (aaaaaa : Nat)
      (bbbbbb : Nat)
      (cccccc : Nat)
      : Nat := aaaaaa                     -- PARSE-PRESERVING

The continuation column (2) is read off the *output* at implementation time and reparse-checked at every
margin (the prompt's Stop condition), not asserted here — `declSig`/`optDeclSig`'s
`many (ppSpace >> …) >> typeSpec` carries no column check, so any column reparses.

### 1.3 `matchAlt` — its over-margin case is an offside re-indent, not a β-break

`matchAlt` = `"| " >> ppIndent (… >> darrow >> checkColGe "…" >> rhsParser)`
(`Lean/Parser/Term.lean:265-270`; reproduced in `spacingOf`'s docstring). Two structural facts move it
out of the β-break's shape:

1. **It leads with a token.** Its parts are `[token("|"), child(pats), token("=>"), child(rhs)]`. The
   β-mechanism breaks before *every* part after the head, which here is `token("|")` — so a uniform break
   would emit `|`↵`  0 =>`↵`  111111`, splitting the `|` from its pattern. The only canonical break is
   `| 0 =>`↵`  111111` — break before the **rhs child only**, a *selective* break point unlike `app`.
2. **Arms are already laid out one-per-line by the grammar.** `matchAlts := withPosition $ many1Indent
   (ppLine >> matchAlt)` (`:279-280`) separates alternatives by `checkColEq >> checkLinebreakBefore` — so
   a multi-arm match is *never* single-line, and the whole match is not a `mayCollapse` command. The only
   over-margin case a β-break could touch is a **single arm whose rhs exceeds the margin**, and putting
   that rhs on its own indented line under `checkColGe` is precisely an **offside re-indent** — the
   `RLF-OFFSIDE`/`RLF-BLOCKS` primitive, which lands a block at a canonical base column preserving its
   internal column checks — not a margin-driven β-break of a flat line.

`matchAlt`'s rhs break is therefore assigned to the offside layer, cited, and its coverage-table row
reads *offside-laid-out (arms one-per-line by `matchAlts`; long-rhs re-indent owned by the offside
primitive)* — a grammatical layer assignment, not a deferred β-break. This is the honest reading of the
prompt's "matchAlt": the construct is covered, by the layer whose invariant it actually lives under.

## 2. Design the break policy twice

The `app`-only mechanism (`termDoc`, `Printer.lean:1173-1199`) emits `.group (head ++ .nest 2 tail)`
where `tail` breaks before **every** part after the head. Extending it needs a decision about break-point
selection.

### Design A — uniform every-part break (widen the gate only)

Keep the mechanism verbatim; widen the gate from `reflows kind` to `reflows kind ||
spacing.isDeclared`, and add `optDeclSig`/`declSig` to `reflows`. Every part after the head breaks.

- **Operators** → `op_appstyle` (operator alone on its own line). Parse-safe (§1.1). But the operator
  atom gets a whole line, doubling the line count of a broken chain and reading nothing like Black.
- **Binders** → break before each binder. This *is* canonical — a binder is a whole part, and `app`'s
  every-part rule already produces the right shape.
- **matchAlt** → splits `|` from its pattern (§1.3); non-canonical, and the wrong layer anyway.
- **Cost:** ~2 lines of code (the gate) plus a `Spacing` for `optDeclSig`.
- **Verdict:** correct and cheap for binders; wrong shape for operators; wrong for matchAlt.

### Design B — per-kind break-point selection

Add a small predicate deciding, per kind, *which* gaps are break points, and glue the non-break parts to
their neighbour under the same `group`/`nest`:

- **`app`** and **binders (`optDeclSig`)** → break before every child part. (Token parts don't occur
  between args/binders, so "before every part" and "before every child" coincide — the existing behaviour
  is a special case of the new rule, so the `app` golden is unchanged.)
- **Operators (fact-covered)** → break before the operator *token* and glue the following operand to it:
  `op_lead`, `left`↵`  + right`. This is Black's binary-operator convention (operator starts the
  continuation line), and it collapses a chain to one operand-per-line at a single column (§1.1's
  same-column property).
- **matchAlt** → not handled here; offside-owned (§1.3).
- **Cost:** one predicate (`breakBefore : kind → Part → Bool`, roughly "before a child, unless the kind is
  a fact-covered notation, in which case before the operator token") and a gluing branch in the `tail`
  loop.
- **Verdict:** canonical for all β-breakable kinds; more code; the operator shape must be reparse-checked
  after implementation (already done for the hand-built shapes in §1.1, to be re-checked on real output).

### Comparison

| axis | Design A (uniform) | Design B (per-kind) |
| --- | --- | --- |
| operator output | operator alone (non-canonical) | `op_lead`, Black-style (canonical) |
| binder output | canonical | canonical |
| chain compactness | 2n+1 lines | n+1 lines |
| parse-safety | proven (§1.1) | proven (§1.1) |
| idempotence | free (broken ⇒ multi-line ⇒ `mayCollapse=false` ⇒ bytes preserved) | same |
| code cost | ~2 lines | one predicate + a glue branch |
| deep-module cost | none new | one concept: "break point ≠ every gap" |

Both are parse-safe; the decision is purely output quality against a small amount of code.

**Decision: Design B**, scoped to operators/notations (`op_lead`) and binder signatures
(`optDeclSig`/`declSig`, break-before-each-binder). The extra concept it introduces — a per-kind break
point — is not speculative generality: it is *forced* by the fact that `matchAlt` leads with a token and
operators want their token on the continuation line, both established first-hand above. A uniform break
would ship knowingly non-canonical operator output for the headline "Black-for-Lean" feature, which is
the wrong trade for the two lines it saves. `matchAlt` is not built here; it is assigned to the offside
layer with the §1.3 citation.

## 3. The gate is fact-driven, not a kind list

`reflows` currently takes only a `kind : String`, but operators cannot be reached by kind (§1.1). The
gate moves to the point where the spacing is already known — `termDoc`'s break branch, which holds
`(spacing, parts) := tree.nodeSpacing node`. The condition becomes:

> a node breaks when `reflows (kindOf node)` **or** its spacing is `.declared` (the fact covers it),
> *and* `parts.size ≥ 2`, *and* the `clean` guard holds.

This is principled rather than enumerative: the set of breakable notations is exactly the set the
`ruff-05b` fact describes, which is the same fact that gives them their spacing — so a notation is broken
on the same authority by which it is spaced, and a notation with no fact stays on the lossless flat path.
`reflows` keeps `app` (and gains `optDeclSig`/`declSig` for binders); the `.declared` disjunct adds the
operators. No kind is hardcoded that the fact does not already own.

## 4. What this prompt ships, and what it does not

- **Ships:** operator/notation breaking (`op_lead`, fact-gated) and binder-signature breaking
  (`optDeclSig`/`declSig`, break-before-each-binder), each reparse-proven at every margin, each consuming
  the `RLF-NOTATION` declared spacing for its separators.
- **Assigns to the offside layer, cited:** `matchAlt`'s long-rhs re-indent (§1.3). The coverage table
  records match arms as offside-laid-out, not as a deferred β-break — so `RLF-REFLOW-ACCEPT`'s "zero
  deferred *breaking* behaviour" holds: there is no β-break waiting on a later prompt, only a construct
  that lives in a different, already-built layer.
- **Unchanged:** the safety envelope (`mayCollapse`, the `clean` guard, the align-free
  break-before-tail), so the corpus round-trips and idempotence is free.
