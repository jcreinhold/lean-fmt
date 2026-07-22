/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Structural declaration documents over actual command syntax.

Shared value declarations use their parser nodes for declaration id, binder list, optional result,
and simple value. Their flat and broken forms are lean-fmt documents; nested type/body syntax remains
an exact token row until the term layer replaces it. Other closed declaration families stay with the
live registry while this module owns their dispatch boundary. Project command wrappers are not
recognized here. -/

import Lean.Parser.Command
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Syntax

namespace LeanFmt.Internal

namespace Formatter.Declaration

private def handles (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.declaration ||
    stx.isOfKind ``Lean.Parser.Command.mutual ||
    stx.isOfKind ``Lean.Parser.Command.deriving

private def simpleKind (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.abbrev ||
    stx.isOfKind ``Lean.Parser.Command.definition ||
    stx.isOfKind ``Lean.Parser.Command.theorem ||
    stx.isOfKind ``Lean.Parser.Command.opaque ||
    stx.isOfKind ``Lean.Parser.Command.instance ||
    stx.isOfKind ``Lean.Parser.Command.axiom ||
    stx.isOfKind ``Lean.Parser.Command.example

private def isSignature (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.declSig ||
    stx.isOfKind ``Lean.Parser.Command.optDeclSig

private def isSimpleValue (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.declValSimple

private partial def findDescendant? (predicate : Lean.Syntax → Bool)
    (stx : Lean.Syntax) : Option Lean.Syntax :=
  if predicate stx then some stx else stx.getArgs.findSome? (findDescendant? predicate)

private def isBinder (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Term.explicitBinder ||
    stx.isOfKind ``Lean.Parser.Term.implicitBinder ||
    stx.isOfKind ``Lean.Parser.Term.strictImplicitBinder ||
    stx.isOfKind ``Lean.Parser.Term.instBinder ||
    stx.isOfKind ``Lean.Parser.Term.binderIdent

private partial def signatureParts (stx : Lean.Syntax) (binders : Array Lean.Syntax)
    (typeSpec? : Option Lean.Syntax) : Array Lean.Syntax × Option Lean.Syntax :=
  if isBinder stx then (binders.push stx, typeSpec?)
  else if stx.isOfKind ``Lean.Parser.Term.typeSpec then (binders, some stx)
  else stx.getArgs.foldl (init := (binders, typeSpec?)) fun (binders, typeSpec?) child =>
    signatureParts child binders typeSpec?

private structure SimpleParts where
  leading : Array String := #[]
  signature? : Option Lean.Syntax := none
  value? : Option Lean.Syntax := none
  trailing : Array String := #[]

private def simpleParts (modifiers inner : Lean.Syntax) : SimpleParts :=
  let initial : SimpleParts := { leading := Syntax.spellings modifiers }
  inner.getArgs.foldl (init := initial) fun parts child =>
    match findDescendant? isSignature child, findDescendant? isSimpleValue child with
    | some signature, _ => { parts with signature? := some signature }
    | _, some value => { parts with value? := some value }
    | _, _ =>
      if parts.value?.isSome then
        { parts with trailing := parts.trailing ++ Syntax.spellings child }
      else
        { parts with leading := parts.leading ++ Syntax.spellings child }

private def typeDocument (typeSpec : Lean.Syntax) : Doc :=
  let tokens := Syntax.spellings typeSpec
  let body := if tokens[0]? == some ":" then tokens.extract 1 tokens.size else tokens
  Doc.text " :" ++ Doc.nest 2 (Doc.line " " ++ Syntax.flat body)

private def valueDocument (value : Lean.Syntax) : Doc :=
  let tokens := Syntax.spellings value
  let body := if tokens[0]? == some ":=" then tokens.extract 1 tokens.size else tokens
  Doc.text " :=" ++ Doc.nest 2 (Doc.line " " ++ Syntax.flat body)

private partial def hasOffsideBody (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Term.do ||
    stx.isOfKind ``Lean.Parser.Term.match ||
    stx.isOfKind ``Lean.Parser.Term.whereDecls ||
    stx.isOfKind ``Lean.Parser.Term.matchAlts ||
    stx.getArgs.any hasOffsideBody

private def simpleDocument? (stx : Lean.Syntax) : Option Doc := do
  let #[modifiers, inner] := stx.getArgs | none
  if !simpleKind inner then none else
  let parts := simpleParts modifiers inner
  let tokens := Syntax.spellings inner
  if parts.value?.isNone && (tokens.contains ":=" || tokens.contains "where") then none else
  if parts.value?.any hasOffsideBody then none else
  let mut document := Syntax.flat parts.leading
  if let some signature := parts.signature? then
    let (binders, typeSpec?) := signatureParts signature #[] none
    for binder in binders do
      document := document ++ Doc.nest 2
        (Doc.line " " ++ Syntax.flat (Syntax.spellings binder))
    if let some typeSpec := typeSpec? then document := document ++ typeDocument typeSpec
  if let some value := parts.value? then document := document ++ valueDocument value
  unless parts.trailing.isEmpty do
    document := document ++ Doc.nest 2
      (Doc.line " " ++ Syntax.flat parts.trailing)
  return Doc.group document

/-- Format a closed declaration command, or return `none` for a non-declaration command. Shared
simple declarations receive structural flat/broken documents when comment-free; other declaration
families retain the live registry document and trace. -/
def format? (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Option (Except FormatterFailure RegisteredDocument)) := do
  if !handles stx then return none
  let registered ← Formatter.registered ownership .command stx
  match simpleDocument? stx with
  | some document =>
    if (Comments.subtree ownership stx).isEmpty then
      let trace := match registered with
        | .ok value => value.trace
        | .error failure => failure.trace
      return some (.ok { document, trace })
    else
      return some registered
  | none => return some registered

end Formatter.Declaration

end LeanFmt.Internal
