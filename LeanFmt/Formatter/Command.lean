/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Core command-shell ownership over actual parsed syntax.

The public operation deliberately reports only the ownership boundary needed by whole-module
composition. Header syntax and Lean's built-in command namespace are closed formatter-owned shells;
all other command kinds are open project syntax and stay with the live formatter registry. Dedicated
structural layers compose core declarations, terms, tactics, control forms, and blocks without
delegating their command ancestor.

This classification is structural rather than a spelling database: adding a new project command does
not require changing lean-fmt, and adding a new toolchain command under `Lean.Parser.Command` enters
the closed core side automatically. -/

import Lean.Parser.Module
import Lean.Parser.Syntax
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Declaration
import all LeanFmt.Formatter.Syntax
import all LeanFmt.Formatter.Trivia

namespace LeanFmt.Internal

/-- Whether an actual command document belongs to lean-fmt's closed shell layer or the environment's
open formatter registry. -/
inductive CommandDocumentOwner where
  | core
  | registry
  deriving Inhabited, BEq, Repr

/-- Whether the selected command document was built by lean-fmt's structural rules or emitted by
Lean's live registry. Syntax provenance and document mechanism are deliberately separate. -/
inductive CommandDocumentMechanism where
  | structural
  | registry
  deriving Inhabited, BEq, Repr

/-- A formatted header or command and the boundary that owns its outer syntax. -/
structure CommandDocument where
  document : Doc
  trace : FormatterTrace
  owner : CommandDocumentOwner
  mechanism : CommandDocumentMechanism
  deriving Inhabited

/-- Owner-relative placement of one command in the module stream. -/
structure CommandPlacement where
  indent : Nat
  blankBefore : Bool
  deriving Inhabited, BEq, Repr

private inductive CommandRole where
  | scopeOpen
  | scopeClose
  | setup
  | declaration
  deriving Inhabited, BEq

/-- Width-independent state for structural command composition. Its representation is private so the
caller cannot infer nesting from source columns or manufacture a different spacing policy. -/
structure CommandSequence where
  private previous? : Option CommandRole := none

namespace Formatter.Command

def sequence : CommandSequence := {}

private def role (stx : Lean.Syntax) : CommandRole :=
  if stx.isOfKind ``Lean.Parser.Command.namespace ||
      stx.isOfKind ``Lean.Parser.Command.section then
    .scopeOpen
  else if stx.isOfKind ``Lean.Parser.Command.end then
    .scopeClose
  else if stx.isOfKind ``Lean.Parser.Command.open ||
      stx.isOfKind ``Lean.Parser.Command.export ||
      stx.isOfKind ``Lean.Parser.Command.universe ||
      stx.isOfKind ``Lean.Parser.Command.variable ||
      stx.isOfKind ``Lean.Parser.Command.set_option then
    .setup
  else
    .declaration

private def separated (previous current : CommandRole) : Bool :=
  match previous, current with
  | .setup, .setup => false
  | .scopeOpen, .scopeClose => false
  | _, _ => true

/-- Advance the structural module stream and return its vertical boundary. Lean's command style keeps
top-level commands at column zero even inside namespaces and sections; indentation belongs to command
internals, not to the module stream. -/
def place (state : CommandSequence) (stx : Lean.Syntax) : CommandSequence × CommandPlacement :=
  let current := role stx
  let blankBefore := state.previous?.any (separated · current)
  (⟨some current⟩, { indent := 0, blankBefore })

private partial def contractFrom (stx : Lean.Syntax) (entries : Array String) : Array String :=
  match stx with
  | .missing => entries.push "missing"
  | .atom _ value => entries.push ("atom:" ++ value)
  | .ident _ raw _ _ => entries.push ("ident:" ++ raw.toString)
  | .node _ kind children =>
    if kind == Lean.choiceKind then
      match children[0]? with
      | some selected => contractFrom selected entries
      | none => entries.push "choice:empty"
    else
      children.foldl (init := entries.push ("node:" ++ kind.toString)) fun result child =>
        contractFrom child result

/-- Location-independent header structure. Token spellings remain exact; whitespace and source
positions are intentionally absent. -/
def headerContract (stx : Lean.Syntax) : Array String :=
  contractFrom stx #[]

private def stripInfo (start stop : Nat) : Lean.SourceInfo → Lean.SourceInfo
    | .original leading position trailing endPos =>
      let leading := if leading.startPos.byteIdx < start then
          { leading with stopPos := leading.startPos }
        else leading
      let trailing := if stop < trailing.stopPos.byteIdx then
          { trailing with stopPos := trailing.startPos }
        else trailing
      .original leading position trailing endPos
    | info => info

private partial def stripBoundaries (start stop : Nat) : Lean.Syntax → Lean.Syntax
    | .node info kind children =>
      .node (stripInfo start stop info) kind (children.map (stripBoundaries start stop))
    | .atom info value => .atom (stripInfo start stop info) value
    | .ident info raw value preresolved => .ident (stripInfo start stop info) raw value preresolved
    | .missing => .missing

/-- Remove only trivia physically outside an ordinary command's token range. Interior comments remain
with the live registry until their structural owner formats them. -/
def boundaryFree (stx : Lean.Syntax) : Lean.Syntax :=
  let start := stx.getRange?.map (·.start.byteIdx) |>.getD 0
  let stop := stx.getRange?.map (·.stop.byteIdx) |>.getD start
  stripBoundaries start stop stx

private def format (ownership : CommentOwnership) (owner : CommandDocumentOwner)
    (category : FormatterCategory) (stx : Lean.Syntax) (clearHead := true) :
    Lean.CoreM (Except FormatterFailure CommandDocument) := do
  let formattedSyntax := if clearHead then boundaryFree stx else stx.unsetTrailing
  let result ← Formatter.registeredAs ownership category stx formattedSyntax
  let document := result.map fun registered =>
    { document := registered.document, trace := registered.trace, owner, mechanism := .registry }
  return document

private def ownerOf (stx : Lean.Syntax) : Lean.CoreM CommandDocumentOwner := do
  return match CoreSurface.owner (← Lean.getEnv) .command stx.getKind with
    | .extension => .registry
    | _ => .core

private structure SelectedToken where
  stx : Lean.Syntax
  spelling : String
  docSyntax : Bool := false
  compact : Bool := false
  deriving Inhabited

private partial def selectedTokens (stx : Lean.Syntax)
    (tokens : Array SelectedToken := #[]) (docSyntax := false) (compact := false) :
    Array SelectedToken :=
  match stx with
  | .missing => tokens
  | .atom _ spelling =>
    if spelling.isEmpty then tokens else tokens.push { stx, spelling, docSyntax, compact }
  | .ident _ raw _ _ =>
    let spelling := raw.toString
    if spelling.isEmpty then tokens else tokens.push { stx, spelling, docSyntax, compact }
  | .node _ kind children =>
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    let docSyntax := docSyntax || kind == ``Lean.Parser.Command.docComment
    let compact := compact || kind == `antiquotName
    children.foldl (init := tokens) fun tokens child =>
      selectedTokens child tokens docSyntax compact

private def hasTrailingLine (ownership : CommentOwnership) (stx : Lean.Syntax) : Bool :=
  (Comments.trailing ownership stx).any fun comment => comment.kind == .line

private def ownedSelectedTokensDocument (ownership : CommentOwnership)
    (tokens : Array SelectedToken) (breakable := true) (emitFirstLeading := true)
    (emitFinalTrailing := true) : Doc := Id.run do
  let some first := tokens[0]? | return Doc.empty
  let tokenText := fun (token : SelectedToken) =>
    if token.spelling.contains '\n' then Doc.verbatim token.spelling else Doc.text token.spelling
  let firstDocument :=
    if first.docSyntax then tokenText first
    else if !emitFirstLeading && tokens.size == 1 && !emitFinalTrailing then tokenText first
    else if !emitFirstLeading then
      Trivia.decorateTrailingBeforeBoundary ownership first.stx (tokenText first)
    else if tokens.size == 1 && !emitFinalTrailing then
      Trivia.decorateLeading ownership first.stx (tokenText first)
    else Trivia.decorateBeforeBoundary ownership first.stx (tokenText first)
  let mut document := firstDocument
  for index in [1:tokens.size] do
    let previous := tokens[index - 1]!
    let token := tokens[index]!
    let boundary := if (previous.docSyntax && !token.docSyntax) ||
        (!previous.docSyntax && hasTrailingLine ownership previous.stx) ||
        (!token.docSyntax && !(Comments.leading ownership token.stx).isEmpty) then
      Doc.hard
    else if token.compact then Doc.empty
    else if Syntax.separatesAfter (tokens[index - 2]?.map (·.spelling))
        previous.spelling token.spelling then
      if breakable then Doc.line " " else Doc.text " "
    else Doc.empty
    let tokenDocument := if token.docSyntax then tokenText token
      else if index + 1 == tokens.size && !emitFinalTrailing then
        Trivia.decorateLeading ownership token.stx (tokenText token)
      else Trivia.decorateBeforeBoundary ownership token.stx (tokenText token)
    document := document ++ boundary ++ tokenDocument
  Doc.group document

private def ownedTokensDocument (ownership : CommentOwnership) (stx : Lean.Syntax)
    (outerCommandBoundary := true) (breakable := true) : Doc :=
  Trivia.decorateBeforeBoundary ownership stx <|
    ownedSelectedTokensDocument ownership (selectedTokens stx) (breakable := breakable)
      (emitFirstLeading := !outerCommandBoundary)
      (emitFinalTrailing := true)

private def headerTokensDocument (ownership : CommentOwnership) (stx : Lean.Syntax) : Doc :=
  let tokens := selectedTokens stx
  let document := ownedSelectedTokensDocument ownership tokens (emitFirstLeading := false)
    (emitFinalTrailing := false)
  let document := match tokens[0]? with
    | some token => Trivia.decorateLeading ownership token.stx document
    | none => document
  let document := match tokens.back? with
    | some token => Trivia.decorateTrailingBeforeBoundary ownership token.stx document
    | none => document
  Trivia.decorateBeforeBoundary ownership stx document

private partial def headerRowsFrom (ownership : CommentOwnership) (stx : Lean.Syntax)
    (rows : Array Doc) : Array Doc :=
  if stx.isOfKind ``Lean.Parser.Module.import then
    rows.push (headerTokensDocument ownership stx)
  else match stx with
    | .atom _ value =>
      if value == "module" || value == "prelude" then
        rows.push (Trivia.decorateBeforeBoundary ownership stx (Doc.text value))
      else rows
    | .node _ _ children =>
      children.foldl (init := rows) fun result child => headerRowsFrom ownership child result
    | _ => rows

private def headerDocument? (ownership : CommentOwnership) (stx : Lean.Syntax) : Option Doc :=
  if stx.isOfKind ``Lean.Parser.Module.header then
    let rows := headerRowsFrom ownership stx #[]
    let document? : Option Doc := rows.foldl (init := none) fun document? row =>
      some <| document?.map (· ++ Doc.hard ++ row) |>.getD row
    some (document?.getD Doc.empty)
  else none

private def simpleShellKinds : Array Lean.Name := #[
  ``Lean.Parser.Command.moduleDoc,
  ``Lean.Parser.Command.namespace,
  ``Lean.Parser.Command.section,
  ``Lean.Parser.Command.end,
  ``Lean.Parser.Command.open,
  ``Lean.Parser.Command.export,
  ``Lean.Parser.Command.universe,
  ``Lean.Parser.Command.variable,
  ``Lean.Parser.Command.attribute,
  ``Lean.Parser.Command.include,
  ``Lean.Parser.Command.omit,
  ``Lean.Parser.Command.check,
  ``Lean.Parser.Command.check_failure,
  ``Lean.Parser.Command.eval,
  ``Lean.Parser.Command.evalBang,
  ``Lean.Parser.Command.synth,
  ``Lean.Parser.Command.print,
  ``Lean.Parser.Command.printSig,
  ``Lean.Parser.Command.printAxioms,
  ``Lean.Parser.Command.printEqns,
  ``Lean.Parser.Command.version,
  ``Lean.Parser.Command.assertNotExists,
  ``Lean.Parser.Command.assertNotImported,
  ``Lean.Parser.Command.checkAssertions,
  ``Lean.Parser.Command.deprecatedSyntax,
  ``Lean.Parser.Command.deprecated_module,
  ``Lean.Parser.Command.showDeprecatedModules,
  ``Lean.Parser.Command.addDocString,
  ``Lean.Parser.Command.register_tactic_tag,
  ``Lean.Parser.Command.recommended_spelling,
  ``Lean.Parser.Command.mixfix,
  ``Lean.Parser.Command.notation,
  ``Lean.Parser.Command.syntax,
  ``Lean.Parser.Command.syntaxAbbrev,
  ``Lean.Parser.Command.syntaxCat,
  ``Lean.Parser.Command.macro,
  ``Lean.Parser.Command.binderPredicate
]

private def grammarShellKinds : Array Lean.Name := #[
  ``Lean.Parser.Command.namespace,
  ``Lean.Parser.Command.section,
  ``Lean.Parser.Command.end,
  ``Lean.Parser.Command.deprecatedSyntax,
  ``Lean.Parser.Command.mixfix,
  ``Lean.Parser.Command.notation,
  ``Lean.Parser.Command.syntax,
  ``Lean.Parser.Command.syntaxAbbrev,
  ``Lean.Parser.Command.syntaxCat,
  ``Lean.Parser.Command.macro,
  ``Lean.Parser.Command.binderPredicate
]

private def isPlainSetOption (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Command.set_option &&
    !(Syntax.spellings stx).contains "in"

private def isVariableBinder (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Term.explicitBinder ||
    stx.isOfKind ``Lean.Parser.Term.implicitBinder ||
    stx.isOfKind ``Lean.Parser.Term.strictImplicitBinder ||
    stx.isOfKind ``Lean.Parser.Term.instBinder ||
    stx.isOfKind ``Lean.Parser.Term.binderIdent

private partial def variableBinders (stx : Lean.Syntax) (result : Array Lean.Syntax := #[]) :
    Array Lean.Syntax :=
  if isVariableBinder stx then result.push stx
  else stx.getArgs.foldl (init := result) fun result child => variableBinders child result

private def variableDocument (ownership : CommentOwnership) (stx : Lean.Syntax) : Doc := Id.run do
  let binders := variableBinders stx
  let mut document := Doc.text "variable"
  let mut previous? : Option SelectedToken := none
  for index in [0:binders.size] do
    let binder := binders[index]!
    let boundary := match previous? with
      | some previous => if hasTrailingLine ownership previous.stx then Doc.hard else Doc.line " "
      | none => Doc.line " "
    let tokens := selectedTokens binder
    let binderDocument := match tokens.back? with
      | some token =>
        Trivia.decorateBeforeBoundary ownership token.stx (Syntax.flat (Syntax.spellings binder))
      | none => Syntax.flat (Syntax.spellings binder)
    document := document ++ Doc.nest 2 (boundary ++ binderDocument)
    previous? := tokens.back?
  Doc.group document

private def simpleShellDocument? (ownership : CommentOwnership) (stx : Lean.Syntax) : Option Doc :=
  if simpleShellKinds.contains stx.getKind || isPlainSetOption stx then
    if stx.isOfKind ``Lean.Parser.Command.moduleDoc then
      -- The complete docstring is command syntax. Its opening token is also represented in comment
      -- ownership, but emitting that logical assignment separately would duplicate `/-!`.
      some (Syntax.flat (Syntax.spellings stx))
    else if stx.isOfKind ``Lean.Parser.Command.variable then
      some (variableDocument ownership stx)
    else
      some (ownedTokensDocument ownership stx
        (breakable := !grammarShellKinds.contains stx.getKind))
  else none

private def structural (ownership : CommentOwnership) (stx : Lean.Syntax) (document : Doc) :
    Lean.CoreM CommandDocument := do
  return {
    document
    trace := ← Formatter.trace ownership .command stx
    owner := .core
    mechanism := .structural }

/-- Format the parsed module/import header as one closed structural document. Import order, modifiers,
and exact-node comments remain those of the actual selected header syntax. -/
def header (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure CommandDocument) := do
  if let some document := headerDocument? ownership stx then
    let trace ← Formatter.trace ownership (.named ``Lean.Parser.Module.header) stx
    return .ok { document, trace, owner := .core, mechanism := .structural }
  format ownership .core (.named ``Lean.Parser.Module.header) stx (clearHead := false)

private def macroRulesDocument (ownership : CommentOwnership) (stx : Lean.Syntax) : Doc := Id.run do
  let tokens := selectedTokens stx
  let rows := tokens.foldl (init := #[]) fun (rows : Array (Array SelectedToken)) token =>
    if token.spelling == "|" then rows.push #[token]
    else match rows.back? with
      | some row => rows.set! (rows.size - 1) (row.push token)
      | none => #[#[token]]
  let mut document? : Option Doc := none
  for index in [0:rows.size] do
    let row := rows[index]!
    let row := ownedSelectedTokensDocument ownership row (breakable := false)
      (emitFirstLeading := index != 0)
      (emitFinalTrailing := index + 1 != rows.size)
    document? := some <| match document? with
      | some document => document ++ Doc.nest 2 (Doc.hard ++ row)
      | none => row
  return Trivia.decorateBeforeBoundary ownership stx (Option.getD document? Doc.empty)

private partial def descendantsOfKind (kind : Lean.Name) (stx : Lean.Syntax)
    (result : Array Lean.Syntax := #[]) : Array Lean.Syntax :=
  if stx.getKind == kind then result.push stx
  else stx.getArgs.foldl (init := result) fun result child =>
    descendantsOfKind kind child result

private def macroDocument? (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  if !stx.isOfKind ``Lean.Parser.Command.macro then return .ok none
  let macroArgs := descendantsOfKind ``Lean.Parser.Command.macroArg stx
  let some tail := descendantsOfKind ``Lean.Parser.Command.macroTail stx |>.back? |
    return .ok none
  let some rhsWrapper := descendantsOfKind ``Lean.Parser.Command.macroRhs tail |>.back? |
    return .ok none
  let some rhs := rhsWrapper.getArgs.find? fun child => !(Syntax.spellings child).isEmpty |
    return .ok none
  let allTokens := selectedTokens stx
  let argumentTokenCount := macroArgs.foldl (init := 0) fun count argument =>
    count + (selectedTokens argument).size
  let tailTokens := selectedTokens tail
  if argumentTokenCount + tailTokens.size > allTokens.size then return .ok none
  let prefixCount := allTokens.size - argumentTokenCount - tailTokens.size
  let prefixDocument := ownedSelectedTokensDocument ownership (allTokens.extract 0 prefixCount)
    (breakable := false) (emitFirstLeading := false)
  let mut document := prefixDocument
  for argument in macroArgs do
    let compact := String.join (Syntax.spellings argument).toList
    document := document ++ Doc.text " " ++ Doc.text compact
  let rhsTokenCount := (selectedTokens rhs).size
  if rhsTokenCount > tailTokens.size then return .ok none
  let tailPrefix := tailTokens.extract 0 (tailTokens.size - rhsTokenCount)
  document := document ++ Doc.text " " ++
    ownedSelectedTokensDocument ownership tailPrefix (breakable := false)
  match ← Formatter.Term.format ownership rhs with
  | .error failure => return .error failure
  | .ok formatted =>
    return .ok (some (Doc.group <| document ++ Doc.nest 2 (Doc.line " " ++ formatted.document)))

/-- Format one actual ordinary command. Built-in command shells are closed; project-defined command
syntax is delegated under the environment and options that parsed it. -/
partial def command (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure CommandDocument) := do
  if stx.isOfKind ``Lean.Parser.Command.in then
    let some nested := stx.getArgs.back? | return ← format ownership .core .command stx
    let allTokens := selectedTokens stx
    let nestedTokenCount := (selectedTokens nested).size
    if nestedTokenCount > allTokens.size then return ← format ownership .core .command stx
    let prefixTokens := allTokens.extract 0 (allTokens.size - nestedTokenCount)
    match ← command ownership nested with
    | .error failure => return .error failure
    | .ok nestedDocument =>
      let prefixDocument := ownedSelectedTokensDocument ownership prefixTokens
        (breakable := false) (emitFirstLeading := false)
      return .ok (← structural ownership stx
        (prefixDocument ++ Doc.hard ++ nestedDocument.document))
  match ← macroDocument? ownership stx with
  | .error failure => return .error failure
  | .ok (some document) => return .ok (← structural ownership stx document)
  | .ok none => pure ()
  if let some document := simpleShellDocument? ownership stx then
    return .ok (← structural ownership stx document)
  if let some declaration ← Formatter.Declaration.format? ownership stx then
    return declaration.map fun formatted =>
      {
        document := formatted.document
        trace := formatted.trace
        owner := .core
        mechanism := if formatted.structural then .structural else .registry }
  if stx.isOfKind ``Lean.Parser.Command.macro_rules then
    return .ok (← structural ownership stx (macroRulesDocument ownership stx))
  let result ← format ownership (← ownerOf stx) .command stx
  match result with
  | .ok formatted => return .ok formatted
  | .error failure => return .error failure

end Formatter.Command

end LeanFmt.Internal
