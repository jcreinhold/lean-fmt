/-
Copyright (c) 2018 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Leonardo de Moura

This file contains a MODIFIED copy of the layout machine from Lean's
`Init/Data/Format/Basic.lean`, vendored from the pinned toolchain
`leanprover/lean4:v4.33.0-rc1` (upstream source path
`src/lean/Init/Data/Format/Basic.lean`; reviewed region: `inductive
Format.FlattenBehavior` through `Format.pretty`).

PROMINENT MODIFICATION NOTICE (Apache-2.0 §4(b)): this file differs from
the upstream source. The changes are:

- declarations are renamed and moved into `LeanFmt.Internal.NativeFormat`;
- `MonadPrettyFormat` is *reused* from `Std.Format`, not copied;
- the entry points `prettyM`/`pretty` are re-expressed as `renderM`/`render`;
- upstream `private` markers are dropped (this repository's module system is
  private-by-default);
- nothing else: the machine's decisions, measures, and emissions are
  upstream's, and `notes/02-native-contract.md` states them as the
  compatibility contract this renderer exists to satisfy.

Deliberately NOT vendored, because the machine does not reach them: the
pretty-printer's formatter registry, parser aliases, and parser internals
(the design's binding boundary); the `ToFormat` instances and constructor
combinators (`bracket`, `paren`, `joinSep`, …), which build documents but
decide nothing; and the `format.*` option surface, which is configuration,
not layout semantics. The golden upstream region this file was reviewed
against is `tests/fixtures/boundary/native-format-region.txt`; the
`boundary` suite's provenance case fails when the pinned toolchain's region
drifts from it, and a toolchain upgrade begins there.
-/

module

/-! The vendored `Std.Format` layout machine. See the copyright header above for provenance and
the modification notice. -/

namespace LeanFmt.Internal.NativeFormat

open Std.Format.MonadPrettyFormat

private structure SpaceResult where
  foundLine              : Bool := false
  foundFlattenedHardLine : Bool := false
  space                  : Nat  := 0
  deriving Inhabited, BEq

@[inline] private def merge (w : Nat) (r₁ : SpaceResult) (r₂ : Nat → SpaceResult) : SpaceResult :=
  if r₁.space > w || r₁.foundLine then
    r₁
  else
    let r₂ := r₂ (w - r₁.space);
    { r₂ with space := r₁.space + r₂.space }

private def spaceUptoLine : Std.Format → Bool → Int → Nat → SpaceResult
  | .nil,         _,       _, _ => {}
  | .line,        flatten, _, _ => if flatten then { space := 1 } else { foundLine := true }
  | .align force, flatten, m, w =>
    if flatten && !force then {}
    else if w < m then
      { space := (m - w).toNat }
    else
      { foundLine := true }
  | .text s,      flatten, _, _ =>
    let p := String.Internal.posOf s '\n'
    let off := String.Internal.offsetOfPos s p
    { foundLine := p != s.rawEndPos, foundFlattenedHardLine := flatten && p != s.rawEndPos,
      space := off }
  | .append f₁ f₂, flatten, m, w => merge w (spaceUptoLine f₁ flatten m w) (spaceUptoLine f₂ flatten m)
  | .nest n f,    flatten, m, w => spaceUptoLine f flatten (m - n) w
  | .group f _,   _,       m, w => spaceUptoLine f true m w
  | .tag _ f,     flatten, m, w => spaceUptoLine f flatten m w

private structure WorkItem where
  f : Std.Format
  indent : Int
  activeTags : Nat

/-- A directive indicating whether a given work group is able to be flattened. Vendored; see the
header. -/
private inductive FlattenAllowability where
  | allow (fits : Bool)
  | disallow
  deriving Inhabited, BEq

/-- Whether the given directive indicates that flattening should occur. -/
private def FlattenAllowability.shouldFlatten : FlattenAllowability → Bool
  | allow true => true
  | _ => false

private structure WorkGroup where
  fla   : FlattenAllowability
  flb   : Std.Format.FlattenBehavior
  items : List WorkItem

private partial def spaceUptoLine' : List WorkGroup → Nat → Nat → SpaceResult
  |   [],                         _,   _ => {}
  |   { items := [],    .. }::gs, col, w => spaceUptoLine' gs col w
  | g@{ items := i::is, .. }::gs, col, w =>
    merge w
      (spaceUptoLine i.f g.fla.shouldFlatten (w + col - i.indent) w)
      (spaceUptoLine' ({ g with items := is }::gs) col)

private def pushGroup (flb : Std.Format.FlattenBehavior) (items : List WorkItem)
    (gs : List WorkGroup) (w : Nat) [Monad m] [Std.Format.MonadPrettyFormat m] : m (List WorkGroup) := do
  let k  ← currColumn
  -- Flatten group if it + the remainder (gs) fits in the remaining space. For `fill`, measure only
  -- up to the next (ungrouped) line break.
  let g  := { fla := .allow (flb == .allOrNone), flb := flb, items := items : WorkGroup }
  let r  := spaceUptoLine' [g] k (w-k)
  let r' := merge (w-k) r (spaceUptoLine' gs k)
  -- Prevent flattening if any item contains a hard line break, except within `fill` if it is
  -- ungrouped (=> unflattened)
  return { g with fla := .allow (!r.foundFlattenedHardLine && r'.space <= w-k) }::gs

private partial def renderWork (w : Nat) [Monad m] [Std.Format.MonadPrettyFormat m] :
    List WorkGroup → m Unit
  | []                           => pure ()
  |   { items := [],    .. }::gs => renderWork w gs
  | g@{ items := i::is, .. }::gs => do
    let gs' (is' : List WorkItem) := { g with items := is' }::gs;
    match i.f with
    | .nil =>
      endTags i.activeTags
      renderWork w (gs' is)
    | .tag t f =>
      startTag t
      renderWork w (gs' ({ i with f, activeTags := i.activeTags + 1 }::is))
    | .append f₁ f₂ => renderWork w (gs' ({ i with f := f₁, activeTags := 0 }::{ i with f := f₂ }::is))
    | .nest n f => renderWork w (gs' ({ i with f, indent := i.indent + n }::is))
    | .text s =>
      let p := String.Internal.posOf s '\n'
      if p == s.rawEndPos then
        pushOutput s
        endTags i.activeTags
        renderWork w (gs' is)
      else
        pushOutput (String.Internal.extract s {} p)
        pushNewline i.indent.toNat
        let is := { i with f := .text (String.Internal.extract s (String.Internal.next s p) s.rawEndPos) }::is
        -- after a hard line break, re-evaluate whether to flatten the remaining group
        -- note that we shouldn't start flattening after a hard break outside a group
        if g.fla == .disallow then
          renderWork w (gs' is)
        else
          pushGroup g.flb is gs w >>= renderWork w
    | .line =>
      match g.flb with
      | .allOrNone =>
        if g.fla.shouldFlatten then
          -- flatten line = text " "
          pushOutput " "
          endTags i.activeTags
          renderWork w (gs' is)
        else
          pushNewline i.indent.toNat
          endTags i.activeTags
          renderWork w (gs' is)
      | .fill =>
        let breakHere := do
          pushNewline i.indent.toNat
          -- make new `fill` group and recurse
          endTags i.activeTags
          pushGroup .fill is gs w >>= renderWork w
        -- if preceding fill item fit in a single line, try to fit next one too
        if g.fla.shouldFlatten then
          let gs'@(g'::_) ← pushGroup .fill is gs (w - String.Internal.length " ")
            | panic "unreachable"
          if g'.fla.shouldFlatten then
            pushOutput " "
            endTags i.activeTags
            renderWork w gs'  -- TODO: use `return`
          else
            breakHere
        else
          breakHere
    | .align force =>
      if g.fla.shouldFlatten && !force then
        -- flatten (align false) = nil
        endTags i.activeTags
        renderWork w (gs' is)
      else
        let k ← currColumn
        if k < i.indent then
          pushOutput (String.Internal.pushn "" ' ' (i.indent - k).toNat)
          endTags i.activeTags
          renderWork w (gs' is)
        else
          pushNewline i.indent.toNat
          endTags i.activeTags
          renderWork w (gs' is)
    | .group f flb =>
      if g.fla.shouldFlatten then
        -- flatten (group f) = flatten f
        renderWork w (gs' ({ i with f }::is))
      else
        pushGroup flb [{ i with f }] (gs' is) w >>= renderWork w

/-- Render `f` with line width `w` and wrap indent `indent`, using the vendored machine.
Upstream's `prettyM`; see the header. -/
def renderM (f : Std.Format) (w : Nat) (indent : Nat := 0) [Monad m] [Std.Format.MonadPrettyFormat m] :
    m Unit :=
  renderWork w
    [{ flb := .allOrNone, fla := .disallow, items := [{ f := f, indent, activeTags := 0 }] }]

/-- State for rendering to a string. Vendored; see the header. -/
private structure State where
  out    : String := ""
  column : Nat    := 0

private instance : Std.Format.MonadPrettyFormat (StateM State) where
  -- We avoid a structure instance update, and write these functions using pattern matching because of issue #316
  pushOutput s       := modify fun ⟨out, col⟩ => ⟨String.Internal.append out s, col + (String.Internal.length s)⟩
  pushNewline indent := modify fun ⟨out, _⟩ => ⟨String.Internal.append out (String.Internal.pushn "\n" ' ' indent), indent⟩
  currColumn         := return (← get).column
  startTag _         := return ()
  endTags _          := return ()

/-- Render `f` to a string. Upstream's `pretty`, column argument included; see the header. -/
def render (f : Std.Format) (width : Nat) (indent : Nat := 0) (column : Nat := 0) : String :=
  let act : StateM State Unit := renderM f width indent
  State.out <| act.run (State.mk "" column) |>.snd

end LeanFmt.Internal.NativeFormat
