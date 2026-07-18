# RLF-RECORDS — the `structInst` A1 break, re-examined against the built engine

`RLF-BLOCKS` designed the record break twice (`notes/08` §2) and chose **A1** (one field per line at a
fixed nest base) over **A2** (fill to margin). This prompt builds A1. The prompt asks whether that choice
survives contact with the engine as it was actually built (through `RLF-OPERATOR-BREAK`). It does — and
building it surfaced one as-built constraint the design stated abstractly but the engine makes concrete.

## 1. A1 vs A2 holds — the engine makes A1 free and A2 expensive, exactly as designed

The renderer accumulates a running indent from the command root and a broken `.line` emits *that* indent
(`Doc.lean:209,229`), independent of the head's output column. So a record laid out as

    .group (.text "{ " ++ .nest 2 (field₁ ++ .text "," ++ .line " " ++ field₂ ++ …) ++ .text " }")

breaks every field `.line` together (all-or-nothing, `RLF-REFLOW` §3 / P1), and because `"{ "` is exactly
two columns and the `nest` is two, field₁ (right after `{ `) and every later field land at the **same**
column — the running indent + 2. That shared column is what `sepByIndent`'s `checkColEq`/`checkColGe`
between fields accepts. **The colEq the record needs is not arranged; it falls out of breaking at a fixed
nest base.** A2 (fill) would pack the first line's fields at descending columns, so the wrap column — which
must still be colEq the *first* field — is a column no later same-line field sits at, and the layout would
have to compute and hold it. A1 gets it from the nest; A2 buys a computed colEq against every axis the
prompt names (diff stability, idempotence, reparse safety). **Decision unchanged: A1.**

## 2. The as-built constraint: a record breaks only where it is line-leading

Operators and binders were "free" because they carry no column check — a broken operand reparses at *any*
column (`notes/09` §1.1). `structInst` is the first β-breakable kind that carries one: `sepByIndent`
re-establishes a `withPosition` inside the braces (`Term.lean:353`, `spacingOf` docstring), so a field on a
continuation line must be `checkColGe`/`checkColEq` the **first field's column**. The A1 nest base equals
the field anchor *only when the record's `{` sits at the running indent* — i.e. when the record is
**line-leading**. A record rendered mid-line (its `{` to the right of the running indent) would anchor its
first field to the right of where the nest breaks the rest, and every continuation would land left of the
anchor — `checkColGe` fails, the parse changes. This is precisely the mid-line-anchor hazard `notes/08`
§1a named; the engine turns it from a caution into an exact condition.

The engine already has the mechanism that makes a record line-leading: **`leadFlat`** (move-value-down).
A `:=` value that exceeds the margin hangs on its own indented line, so its head lands at the indent base
(`termClaims`, `RLF-REFLOW`). For `def f : T := { … }` that base is where `{` goes, so field₁ anchors at
base + 2 and the nest breaks the rest to base + 2. The break is armed **only** in this position:

- `structInst` joins the `leadFlat` gate and is claimed as a term (it was `keep`, hence unclaimed).
- `termDoc` emits the A1 body (fields as `.line`-separated parts, **no group of its own**) only under the
  `breakRecord` flag, which `termClaims` sets **iff** the record is the `leadFlat` value.
- Recursion into fields passes `breakRecord := false`, so a **nested** record (a field's value, which is
  mid-line after `field :=`) takes the flat/`keep` path and keeps its bytes. This is the conservative
  fallback `notes/08` §4 already scoped out; the engine enforces it structurally rather than by a column
  guess.

Because the A1 body carries no group of its own, its field `.line`s break exactly when the enclosing
`leadFlat` group breaks — the same event that placed the record line-leading. Break and safety coincide by
construction, not by a runtime column test. A record that fits stays flat: the `leadFlat` group renders
flat, the field `.line`s render as their one-space flat spelling, and the result is the canonical
`{ x := 1, y := 2 }` — byte-identical to canonical source (the corpus round-trips).

## 3. Scope, restated as built

- **Breaks (A1):** a single-line-over-margin `structInst` in `leadFlat` position (`:=` value) with no
  `with`-clause, type ascription, or `..` ellipsis — the plain field-list record. Every other shape (a
  `with`/typed/ellipsis record, or a non-`leadFlat` record) takes the flat/`keep` path.
- **Never collapses:** a multi-line record is `mayCollapse=false` (multi-line command) and is never joined
  upward — the `sepByIndent`-saves-inside collapse hazard (`results/02` §5b) stays deferred, unchanged.
- **Comments:** a comment between fields makes the field gap non-clean, so the record keeps its bytes
  rather than break — the comment survives unmoved.
