/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- The runtime boundary between Lean's closed syntax surface and project extensions.

This is deliberately a provenance classifier, not a formatting table. Parser declarations under
`Lean.Parser` and generated parser declarations originating in `Init` or `Lean` are toolchain core;
the parser's universal leaf/wrapper kinds are shared core structure. Everything else is an extension
root and may use the live formatter registry. Canonical layout never appears here.

The originating module matters for generated names such as operator kinds, whose names do not retain a
`Lean.Parser` prefix. Imported project declarations have their own module provenance; declarations made
while processing the current file have no imported-module index and remain extensions unless they use
Lean's reserved parser namespace. -/

import Lean.Parser.Command
import Lean.Parser.Module
import Lean.Parser.Tactic

namespace LeanFmt.Internal

/-- Parser category in which an outer syntax root is being formatted. -/
inductive SurfaceCategory where
  | command
  | term
  | tactic
  | named (name : Lean.Name)
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The structural family responsible for a closed toolchain syntax node. -/
inductive CoreSurfaceFamily where
  | command
  | term
  | tactic
  | shared
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Whether a syntax kind is closed toolchain structure or an open project extension. -/
inductive SurfaceOwner where
  | lexical
  | transparent
  | structural (family : CoreSurfaceFamily)
  | extension
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- One distinct runtime syntax-kind classification. -/
structure SurfaceObservation where
  kind : String
  owner : SurfaceOwner
  originModule? : Option String
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Deterministic inventory of distinct kinds plus occurrence counts from actual parsed syntax. -/
structure SurfaceSummary where
  observations : Array SurfaceObservation
  lexicalOccurrences : Nat
  transparentOccurrences : Nat
  structuralOccurrences : Nat
  extensionOccurrences : Nat
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

namespace CoreSurface

private def parserPrefix : Lean.Name := ``Lean.Parser.Command.declaration |>.getPrefix.getPrefix

private def commandPrefix : Lean.Name := ``Lean.Parser.Command.declaration |>.getPrefix

private def termPrefix : Lean.Name := ``Lean.Parser.Term.app |>.getPrefix

private def tacticPrefix : Lean.Name := ``Lean.Parser.Tactic.tacticSeq |>.getPrefix

private def modulePrefix : Lean.Name := ``Lean.Parser.Module.header |>.getPrefix

private def lexicalKinds : Array Lean.Name := #[
  `ident, `num, `scientific, `str, `char, `name, `fieldIdx, `hygieneInfo,
  `interpolatedStrKind, `interpolatedStrLitKind
]

private def transparentKinds : Array Lean.Name := #[
  `null, `group, `choice, `missing
]

/-- Imported module which declared `kind`, when Lean retained that declaration provenance. -/
def originModule? (env : Lean.Environment) (kind : Lean.Name) : Option Lean.Name := do
  let index ← env.getModuleIdxFor? kind
  env.header.moduleNames[index.toNat]?

private def coreModule (moduleName : Lean.Name) : Bool :=
  (Lean.Name.mkSimple "Init").isPrefixOf moduleName ||
    (Lean.Name.mkSimple "Lean").isPrefixOf moduleName

private def categoryFamily : SurfaceCategory → CoreSurfaceFamily
  | .command => .command
  | .term => .term
  | .tactic => .tactic
  | .named name =>
    if commandPrefix.isPrefixOf name || modulePrefix.isPrefixOf name then .command
    else if tacticPrefix.isPrefixOf name then .tactic
    else if termPrefix.isPrefixOf name then .term
    else .shared

/-- Classify one actual syntax kind without consulting its source spelling or layout. -/
def owner (env : Lean.Environment) (category : SurfaceCategory) (kind : Lean.Name) : SurfaceOwner :=
  if lexicalKinds.contains kind then .lexical
  else if transparentKinds.contains kind then .transparent
  else if commandPrefix.isPrefixOf kind || modulePrefix.isPrefixOf kind then .structural .command
  else if termPrefix.isPrefixOf kind then .structural .term
  else if tacticPrefix.isPrefixOf kind then .structural .tactic
  else if parserPrefix.isPrefixOf kind then .structural (categoryFamily category)
  else if (originModule? env kind).any coreModule then .structural (categoryFamily category)
  else .extension

/-- Whether a registry document at this root is an extension mechanism rather than missing core
ownership. -/
def registryAllowed (env : Lean.Environment) (category : SurfaceCategory) (kind : Lean.Name) : Bool :=
  owner env category kind == .extension

private def nestedCategory (fallback : SurfaceCategory) (kind : Lean.Name) : SurfaceCategory :=
  if commandPrefix.isPrefixOf kind || modulePrefix.isPrefixOf kind then .command
  else if tacticPrefix.isPrefixOf kind then .tactic
  else if termPrefix.isPrefixOf kind then .term
  else fallback

/-- Classify every selected syntax node. A `choice` follows its selected first child exactly as the
source projection and formatter do. -/
partial def observe (env : Lean.Environment) (category : SurfaceCategory) (stx : Lean.Syntax) :
    Array SurfaceObservation :=
  let kind := stx.getKind
  let category := nestedCategory category kind
  let nodeOwner := match stx with
    | .atom .. | .ident .. => SurfaceOwner.lexical
    | .missing => .transparent
    | .node .. => owner env category kind
  let current := {
    kind := toString kind
    owner := nodeOwner
    originModule? := (originModule? env kind).map toString }
  match stx with
  | .node _ nodeKind children =>
    let children := if nodeKind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := #[current]) fun result child => result ++ observe env category child
  | _ => #[current]

/-- Deduplicate observations in first-occurrence order while retaining workload occurrence counts. -/
def summarize (observations : Array SurfaceObservation) : SurfaceSummary := Id.run do
  let mut distinct := #[]
  let mut lexicalOccurrences := 0
  let mut transparentOccurrences := 0
  let mut structuralOccurrences := 0
  let mut extensionOccurrences := 0
  for observation in observations do
    match observation.owner with
    | .lexical => lexicalOccurrences := lexicalOccurrences + 1
    | .transparent => transparentOccurrences := transparentOccurrences + 1
    | .structural _ => structuralOccurrences := structuralOccurrences + 1
    | .extension => extensionOccurrences := extensionOccurrences + 1
    unless distinct.contains observation do distinct := distinct.push observation
  return {
    observations := distinct
    lexicalOccurrences
    transparentOccurrences
    structuralOccurrences
    extensionOccurrences }

end CoreSurface

end LeanFmt.Internal
