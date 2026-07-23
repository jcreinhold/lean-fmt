/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- Structural tactic and `do` blocks over their actual parser children.

The term caller supplies recursive term formatting. Closed tactic and `do` ancestors compose their
sequences, alternatives, fallback arms, and continuations recursively; only a provenance-proved
project leaf reaches the live registry. Every built-in offside form names its parser-child contract.
There is deliberately no token-flattening fallback that attempts to rediscover nested blocks. -/

import Lean.Parser.Do
import Lean.Parser.Tactic
import Lean.Parser.Term
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Syntax
import all LeanFmt.Formatter.Trivia

namespace LeanFmt.Internal.Formatter.Block

private abbrev TermDocument :=
  Lean.Syntax → Lean.CoreM (Except FormatterFailure (Option Doc))

private def nonemptyChildren (stx : Lean.Syntax) : Array Lean.Syntax :=
  stx.getArgs.filter fun child => !(Syntax.spellings child).isEmpty

private partial def firstTokenSyntax? (spelling : String) (stx : Lean.Syntax) : Option Lean.Syntax :=
  match stx with
  | .atom _ value => if value == spelling then some stx else none
  | .ident _ raw _ _ => if raw.toString == spelling then some stx else none
  | .node _ kind children =>
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.findSome? (firstTokenSyntax? spelling)
  | .missing => none

private def join (documents : Array Doc) (separator : Doc) : Doc :=
  match documents[0]? with
  | none => Doc.empty
  | some first => documents.extract 1 documents.size |>.foldl (init := first) fun result document =>
      result ++ separator ++ document

private def isSequenceKind (stx : Lean.Syntax) : Bool :=
  stx.isOfKind ``Lean.Parser.Term.doSeq ||
    stx.isOfKind ``Lean.Parser.Term.doSeqIndent ||
    stx.isOfKind ``Lean.Parser.Term.doSeqBracketed

private partial def properNestedDoContains (stx : Lean.Syntax) (position : Nat) : Bool :=
  stx.getArgs.any fun child =>
    let contains := child.getRange?.any fun range =>
      range.start.byteIdx <= position && position < range.stop.byteIdx
    (child.isOfKind ``Lean.Parser.Term.do && contains) || properNestedDoContains child position

private def trailingBetween (ownership : CommentOwnership) (sequence : Lean.Syntax)
    (start stop : Nat) (document : Doc) : Doc :=
  Comments.subtreeAt ownership sequence .trailing |>.filter (fun comment =>
    start <= comment.range.start && comment.range.start < stop &&
      !properNestedDoContains sequence comment.range.start) |>.foldl
      (init := document) fun document comment =>
    let payload := Comments.payload ownership comment
    let commentDocument := if payload.contains '\n' then Doc.verbatim payload else Doc.text payload
    document ++ Doc.text " " ++ commentDocument

private partial def firstSequence? (stx : Lean.Syntax) : Option Lean.Syntax :=
  if stx.isOfKind ``Lean.Parser.Term.doSeq || stx.isOfKind ``Lean.Parser.Term.doSeqIndent ||
      stx.isOfKind ``Lean.Parser.Term.doSeqBracketed then some stx
  else stx.getArgs.foldl (init := none) fun found nested => found <|> firstSequence? nested

private def letElseContinuation? (stx : Lean.Syntax) : Option Lean.Syntax := do
  guard <| stx.isOfKind ``Lean.Parser.Term.doLetElse
  let continuation ← stx.getArgs[8]?
  firstSequence? continuation

private partial def descendantsOfKind (kind : Lean.Name) (stx : Lean.Syntax)
    (values : Array Lean.Syntax := #[]) : Array Lean.Syntax :=
  if stx.getKind == kind then values.push stx
  else stx.getArgs.foldl (init := values) fun result child =>
    descendantsOfKind kind child result

private def patDeclFallback? (stx : Lean.Syntax) : Option (Lean.Syntax × Lean.Syntax) := do
  let pattern ← stx.getArgs.find? (·.isOfKind ``Lean.Parser.Term.doPatDecl)
  let fallbackPart ← pattern.getArgs[4]?
  let fallback ← fallbackPart.getArgs[1]?
  guard <| (firstSequence? fallback).isSome
  return (pattern, fallback)

private def patDeclContinuation? (stx : Lean.Syntax) : Option Lean.Syntax := do
  let pattern ← stx.getArgs.find? (·.isOfKind ``Lean.Parser.Term.doPatDecl)
  let fallbackPart ← pattern.getArgs[4]?
  let continuation ← fallbackPart.getArgs[2]?
  firstSequence? continuation

private partial def sequenceItems (stx : Lean.Syntax) (items : Array Lean.Syntax := #[]) :
    Array Lean.Syntax :=
  if stx.isOfKind ``Lean.Parser.Term.doSeqItem then
    let result := items.push stx
    match (nonemptyChildren stx)[0]? with
    | some item =>
      match letElseContinuation? item with
      | some continuation => sequenceItems continuation result
      | none =>
        if item.isOfKind ``Lean.Parser.Term.doLetArrow ||
            item.isOfKind ``Lean.Parser.Term.doReassignArrow then
          match patDeclContinuation? item with
          | some continuation => sequenceItems continuation result
          | none => result
        else result
    | none => result
  else if stx.isOfKind ``Lean.Parser.Term.doSeq ||
      stx.isOfKind ``Lean.Parser.Term.doSeqIndent ||
      stx.isOfKind ``Lean.Parser.Term.doSeqBracketed || stx.getKind == Lean.nullKind then
    stx.getArgs.foldl (init := items) fun result nested => sequenceItems nested result
  else items

private partial def wrappedTerm (formatTerm : TermDocument) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  if stx.getKind != Lean.nullKind && stx.getKind != Lean.groupKind then
    match ← formatTerm stx with
    | .ok (some document) => return .ok (some document)
    | .error failure => return .error failure
    | .ok none => pure ()
  for nested in nonemptyChildren stx do
    match ← wrappedTerm formatTerm nested with
    | .ok (some document) => return .ok (some document)
    | .error failure => return .error failure
    | .ok none => pure ()
  return .ok none

private partial def itemValueSyntax? (stx : Lean.Syntax) : Option Lean.Syntax :=
  if stx.isOfKind ``Lean.Parser.Term.doExpr then nonemptyChildren stx |>.back?
  else if stx.isOfKind ``Lean.Parser.Term.letIdDecl ||
      stx.isOfKind ``Lean.Parser.Term.letPatDecl ||
      stx.isOfKind ``Lean.Parser.Term.letIdDeclNoBinders then
    nonemptyChildren stx |>.back?
  else
    stx.getArgs.foldr (init := none) fun nested found => found <|> itemValueSyntax? nested

private def assignmentDocument (formatTerm : TermDocument)
    (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let some valueSyntax := itemValueSyntax? stx | return .ok none
  match ← formatTerm valueSyntax with
  | .error failure => return .error failure
  | .ok none => return .ok none
  | .ok (some value) =>
    let tokens := Syntax.spellings stx
    let valueTokens := Syntax.spellings valueSyntax
    if valueTokens.size > tokens.size then return .ok none
    let prefixDocument := Syntax.flat (tokens.extract 0 (tokens.size - valueTokens.size))
    return .ok (some (Doc.group (prefixDocument ++ Doc.nest 2 (Doc.line " " ++ value))))

private def arrowDocument (formatTerm formatDo : TermDocument) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let some declaration := stx.getArgs.find? fun child =>
      child.isOfKind ``Lean.Parser.Term.doIdDecl ||
        child.isOfKind ``Lean.Parser.Term.doPatDecl | return .ok none
  let args := declaration.getArgs
  let some actionSyntax := args[3]? | return .ok none
  let actionResult ← if actionSyntax.isOfKind ``Lean.Parser.Term.doExpr then
      match nonemptyChildren actionSyntax |>.back? with
      | some term => formatTerm term
      | none => pure (.ok none)
    else formatDo actionSyntax
  match actionResult with
  | .error failure => return .error failure
  | .ok none => return .ok none
  | .ok (some action) =>
    let prefixTokens := stx.getArgs.foldl (init := #[]) fun tokens child =>
      if child.isOfKind ``Lean.Parser.Term.doIdDecl ||
          child.isOfKind ``Lean.Parser.Term.doPatDecl then
        tokens ++ (args.extract 0 3).foldl (init := #[]) fun inner nested =>
          inner ++ Syntax.spellings nested
      else tokens ++ Syntax.spellings child
    return .ok (some (Doc.group <|
      Syntax.flat prefixTokens ++ Doc.nest 2 (Doc.line " " ++ action)))

private def termDocumentOrFlat (formatTerm : TermDocument) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure Doc) := do
  match ← formatTerm stx with
  | .error failure => return .error failure
  | .ok (some document) => return .ok document
  | .ok none => return .ok (Syntax.flat (Syntax.spellings stx))

private def conditionDocument (formatTerm : TermDocument) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure Doc) := do
  if stx.isOfKind ``Lean.Parser.Term.doIfProp then
    let children := nonemptyChildren stx
    let some valueSyntax := children.back? | return .ok Doc.empty
    match ← termDocumentOrFlat formatTerm valueSyntax with
    | .error failure => return .error failure
    | .ok value =>
      if children.size == 1 then return .ok value
      return .ok (Syntax.flat (Syntax.spellings children[0]!) ++ Doc.text " " ++ value)
  if stx.isOfKind ``Lean.Parser.Term.doIfLet then
    let args := stx.getArgs
    let some pattern := args[1]? | return .ok (Syntax.flat (Syntax.spellings stx))
    let some binding := args[2]? | return .ok (Syntax.flat (Syntax.spellings stx))
    let bindingArgs := nonemptyChildren binding
    let some valueSyntax := bindingArgs.back? | return .ok (Syntax.flat (Syntax.spellings stx))
    match ← termDocumentOrFlat formatTerm valueSyntax with
    | .error failure => return .error failure
    | .ok value =>
      let operator := if binding.isOfKind ``Lean.Parser.Term.doIfLetBind then " ← " else " := "
      return .ok (Doc.text "let " ++ Syntax.flat (Syntax.spellings pattern) ++
        Doc.text operator ++ value)
  termDocumentOrFlat formatTerm stx

private def matchAlternativeDocument (ownership : CommentOwnership) (formatDo : TermDocument)
    (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let #[_, patterns, _, bodySyntax] := stx.getArgs | return .ok none
  match ← formatDo bodySyntax with
  | .error failure => return .error failure
  | .ok none => return .ok none
  | .ok (some body) =>
    let header := Doc.text "| " ++ Syntax.flatSyntax patterns ++ Doc.text " =>"
    let document := header ++ Doc.nest 2 (Doc.hard ++ body)
    return .ok (some <| match Trivia.leading ownership stx with
      | some comments => comments ++ Doc.hard ++ document
      | none => document)

private def matchDocument (ownership : CommentOwnership) (formatDo formatTerm : TermDocument)
    (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let args := stx.getArgs
  let some discriminantSyntax := args[4]? | return .ok none
  let some alternatives := args[6]? | return .ok none
  if !alternatives.isOfKind ``Lean.Parser.Term.matchAlts then return .ok none
  let discriminants := descendantsOfKind ``Lean.Parser.Term.matchDiscr discriminantSyntax
  if discriminants.isEmpty then return .ok none
  let mut document := Doc.text "match "
  for index in [:discriminants.size] do
    let discriminant := discriminants[index]!
    let children := nonemptyChildren discriminant
    let some valueSyntax := children.back? | return .ok none
    match ← termDocumentOrFlat formatTerm valueSyntax with
    | .error failure => return .error failure
    | .ok value =>
      if index > 0 then document := document ++ Doc.text ", "
      if children.size > 1 then
        document := document ++ Syntax.flat (Syntax.spellings children[0]!) ++ Doc.text " "
      document := document ++ value
  document := document ++ Doc.text " with"
  for alternative in nonemptyChildren alternatives do
    if alternative.isOfKind ``Lean.Parser.Term.matchAlt then
      match ← matchAlternativeDocument ownership formatDo alternative with
      | .error failure => return .error failure
      | .ok none => return .ok none
      | .ok (some value) => document := document ++ Doc.hard ++ value
    else
      for nested in nonemptyChildren alternative do
        match ← matchAlternativeDocument ownership formatDo nested with
        | .error failure => return .error failure
        | .ok none => return .ok none
        | .ok (some value) => document := document ++ Doc.hard ++ value
  return .ok (some document)

private partial def tacticDocument (ownership : CommentOwnership) (formatTerm : TermDocument)
    (stx : Lean.Syntax) : Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  match stx with
  | .atom _ spelling =>
    return .ok (some (Trivia.decorateBeforeBoundary ownership stx (Doc.text spelling)))
  | .ident .. =>
    return .ok (some (Trivia.decorateBeforeBoundary ownership stx
      (Syntax.flat (Syntax.spellings stx))))
  | _ => pure ()
  match CoreSurface.owner (← Lean.getEnv) .tactic stx.getKind with
  | .extension =>
    return (← Formatter.registeredBoundary ownership .tactic stx).map fun formatted =>
      some <| match Trivia.leading ownership stx with
        | some comments => comments ++ Doc.hard ++ formatted.document
        | none => formatted.document
  | _ => pure ()
  if stx.getKind == Lean.nullKind || stx.getKind == Lean.groupKind ||
      stx.isOfKind ``Lean.Parser.Tactic.tacticSeq ||
      stx.isOfKind ``Lean.Parser.Tactic.tacticSeq1Indented then
    let lexicalContainer := (stx.getKind == Lean.nullKind || stx.getKind == Lean.groupKind) &&
      (nonemptyChildren stx).all fun child => child.isAtom || child.isIdent
    let mut documents := #[]
    for nested in nonemptyChildren stx do
      match ← tacticDocument ownership formatTerm nested with
      | .ok (some document) => documents := documents.push document
      | .ok none => return .ok none
      | .error failure => return .error failure
    if documents.isEmpty then return .ok none
    return .ok (some (join documents (if lexicalContainer then Doc.text " " else Doc.hard)))
  if stx.getKind == ``Lean.cdot then
    let children := nonemptyChildren stx
    let some body := children.back? | return .ok none
    match ← tacticDocument ownership formatTerm body with
    | .ok (some bodyDocument) =>
      let document := Doc.text "·" ++ Doc.nest 2 (Doc.line " " ++ bodyDocument)
      return .ok (some <| match Trivia.leading ownership stx with
        | some comments => comments ++ Doc.hard ++ document
        | none => document)
    | .ok none => return .ok none
    | .error failure => return .error failure
  if stx.isOfKind ``Lean.Parser.Tactic.first then
    let children := nonemptyChildren stx
    let some alternatives := children.back? | return .ok none
    let mut document := Doc.text "first"
    for alternative in nonemptyChildren alternatives do
      let groupChildren := nonemptyChildren alternative
      let some body := groupChildren.back? | return .ok none
      match ← tacticDocument ownership formatTerm body with
      | .ok (some bodyDocument) =>
        let marker := match firstTokenSyntax? "|" alternative with
          | some pipe => Trivia.decorateBeforeBoundary ownership pipe (Doc.text "|")
          | none => Doc.text "|"
        document := document ++ Doc.hard ++ marker ++ Doc.text " " ++ bodyDocument
      | .ok none => return .ok none
      | .error failure => return .error failure
    return .ok (some document)
  if stx.isOfKind ``Lean.Parser.Tactic.match then
    let args := stx.getArgs
    let some discriminantContainer := args[3]? | return .ok none
    let some alternativeContainer := args[5]? | return .ok none
    let discriminants := descendantsOfKind ``Lean.Parser.Term.matchDiscr discriminantContainer
    let alternatives := descendantsOfKind ``Lean.Parser.Term.matchAlt alternativeContainer
    if discriminants.isEmpty || alternatives.isEmpty then return .ok none
    let mut document := Doc.text "match "
    for index in [:discriminants.size] do
      let parts := nonemptyChildren discriminants[index]!
      let some valueSyntax := parts.back? | return .ok none
      match ← termDocumentOrFlat formatTerm valueSyntax with
      | .error failure => return .error failure
      | .ok value =>
        if index > 0 then document := document ++ Doc.text ", "
        if parts.size > 1 then
          let prefixTokens := (parts.extract 0 (parts.size - 1)).foldl (init := #[]) fun tokens part =>
            tokens ++ Syntax.spellings part
          document := document ++ Syntax.flat prefixTokens ++ Doc.text " "
        document := document ++ value
    document := Doc.group (document ++ Doc.text " with")
    for alternative in alternatives do
      match ← matchAlternativeDocument ownership (tacticDocument ownership formatTerm) alternative with
      | .error failure => return .error failure
      | .ok none => return .ok none
      | .ok (some arm) => document := document ++ Doc.hard ++ arm
    return .ok (some document)
  let args := nonemptyChildren stx
  if args.isEmpty then return .ok none
  let mut documents := #[]
  for nested in args do
    match nested with
    | .atom _ spelling =>
      documents := documents.push (Trivia.decorateBeforeBoundary ownership nested (Doc.text spelling))
    | .ident .. =>
      documents := documents.push (Trivia.decorateBeforeBoundary ownership nested
        (Syntax.flat (Syntax.spellings nested)))
    | _ =>
      match CoreSurface.owner (← Lean.getEnv) .tactic nested.getKind with
      | .structural .term =>
        match ← formatTerm nested with
        | .ok (some document) => documents := documents.push document
        | .ok none => return .ok none
        | .error failure => return .error failure
      | _ =>
        match ← tacticDocument ownership formatTerm nested with
        | .ok (some document) => documents := documents.push document
        | .ok none => documents := documents.push (Trivia.decorateBeforeBoundary ownership nested
          (Syntax.flat (Syntax.spellings nested)))
        | .error failure => return .error failure
  if let #[left, _, right] := documents then
    if (Syntax.spellings args[1]!) == #["<;>"] then
      return .ok (some (Doc.group <|
        left ++ Doc.text " <;>" ++ Doc.nest 2 (Doc.line " " ++ right)))
  return .ok (some (join documents (Doc.text " ")))

private partial def doDocument (ownership : CommentOwnership) (formatTerm : TermDocument)
    (stx : Lean.Syntax) : Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  let isSequence := isSequenceKind stx
  if isSequence then
    let mut documents := #[]
    let items := sequenceItems stx
    for index in [:items.size] do
      let nested := items[index]!
      let start := nested.getRange?.map (·.start.byteIdx) |>.getD 0
      let stop := items[index + 1]?.bind (·.getRange?) |>.map (·.start.byteIdx) |>.getD
        (stx.getRange?.map (·.stop.byteIdx) |>.getD start)
      match ← doDocument ownership formatTerm nested with
      | .ok (some document) =>
        documents := documents.push (trailingBetween ownership stx start stop document)
      | .ok none =>
        match ← formatTerm nested with
        | .ok (some document) =>
          documents := documents.push (trailingBetween ownership stx start stop document)
        | .ok none => return .ok none
        | .error failure => return .error failure
      | .error failure => return .error failure
    if documents.isEmpty then return .ok none
    let body := join documents Doc.hard
    if stx.isOfKind ``Lean.Parser.Term.doSeqBracketed then
      return .ok (some (Doc.text "{" ++ Doc.nest 2 (Doc.hard ++ body) ++
        Doc.hard ++ Doc.text "}"))
    return .ok (some body)
  if stx.isOfKind ``Lean.Parser.Term.doSeqItem then
    let children := nonemptyChildren stx
    let some item := children[0]? | return .ok none
    match ← doDocument ownership formatTerm item with
    | .error failure => return .error failure
    | .ok none => return .ok none
    | .ok (some document) =>
      let trailing := children.extract 1 children.size |>.foldl (init := #[]) fun tokens child =>
        tokens ++ Syntax.spellings child
      let document := document ++ Syntax.flat trailing
      return .ok (some <| match Trivia.leading ownership stx with
        | some comments => comments ++ Doc.hard ++ document
        | none => document)
  if stx.isOfKind ``Lean.Parser.Term.doLetElse then
    let args := stx.getArgs
    let some fallback := args[7]? | return .ok none
    let some patternSyntax := args[3]? | return .ok none
    let some valueSyntax := args[5]? | return .ok none
    match ← termDocumentOrFlat formatTerm valueSyntax with
    | .error failure => return .error failure
    | .ok value =>
      match ← doDocument ownership formatTerm fallback with
      | .error failure => return .error failure
      | .ok none => return .ok none
      | .ok (some body) =>
        let modifiers := Syntax.flat <| (args.extract 1 3).foldl (init := #[]) fun tokens child =>
          tokens ++ Syntax.spellings child
        let modifierDocument :=
          if (args.extract 1 3).all fun child => (Syntax.spellings child).isEmpty then Doc.empty
          else modifiers ++ Doc.text " "
        let header := Doc.text "let " ++ modifierDocument ++
          Syntax.flat (Syntax.spellings patternSyntax) ++ Doc.text " := " ++ value ++ Doc.text " |"
        return .ok (some (header ++ Doc.text " " ++ body))
  if stx.isOfKind ``Lean.Parser.Term.doLetArrow ||
      stx.isOfKind ``Lean.Parser.Term.doReassignArrow then
    if let some (pattern, fallback) := patDeclFallback? stx then
      match ← doDocument ownership formatTerm fallback with
      | .error failure => return .error failure
      | .ok none => return .ok none
      | .ok (some body) =>
        let headerTokens := stx.getArgs.foldl (init := #[]) fun tokens child =>
          if child.isOfKind ``Lean.Parser.Term.doPatDecl then
            tokens ++ (pattern.getArgs.extract 0 4).foldl (init := #[]) fun inner nested =>
              inner ++ Syntax.spellings nested
          else tokens ++ Syntax.spellings child
        return .ok (some (Syntax.flat headerTokens ++ Doc.text " | " ++ body))
  if stx.isOfKind ``Lean.Parser.Term.doMatch then
    return ← matchDocument ownership (doDocument ownership formatTerm) formatTerm stx
  if stx.isOfKind ``Lean.Parser.Term.doIf then
    let args := stx.getArgs
    let some conditionSyntax := args[1]? | return .ok none
    let some bodySyntax := args[3]? | return .ok none
    match ← conditionDocument formatTerm conditionSyntax with
    | .error failure => return .error failure
    | .ok condition =>
      match ← doDocument ownership formatTerm bodySyntax with
      | .error failure => return .error failure
      | .ok none => return .ok none
      | .ok (some body) =>
        let mut document := Doc.text "if " ++ condition ++ Doc.text " then" ++
          Doc.nest 2 (Doc.hard ++ body)
        if let some elseIfs := args[4]? then
          for elseIf in nonemptyChildren elseIfs do
            let elseIfArgs := elseIf.getArgs
            let some elseIfConditionSyntax := elseIfArgs[1]? | return .ok none
            let some elseIfBodySyntax := elseIfArgs[3]? | return .ok none
            match ← conditionDocument formatTerm elseIfConditionSyntax with
            | .error failure => return .error failure
            | .ok elseIfCondition =>
              match ← doDocument ownership formatTerm elseIfBodySyntax with
              | .error failure => return .error failure
              | .ok none => return .ok none
              | .ok (some elseIfBody) =>
                document := document ++ Doc.hard ++ Doc.text "else if " ++
                  elseIfCondition ++ Doc.text " then" ++
                    Doc.nest 2 (Doc.hard ++ elseIfBody)
        if let some elsePart := args[5]? then
          if let some elseBody := firstSequence? elsePart then
            match ← doDocument ownership formatTerm elseBody with
            | .error failure => return .error failure
            | .ok none => return .ok none
            | .ok (some value) =>
              document := document ++ Doc.hard ++ Doc.text "else" ++
                Doc.nest 2 (Doc.hard ++ value)
        return .ok (some document)
  if stx.isOfKind ``Lean.Parser.Term.doWhile then
    let args := stx.getArgs
    let some conditionSyntax := args[1]? | return .ok none
    let some bodySyntax := args[3]? | return .ok none
    match ← conditionDocument formatTerm conditionSyntax with
    | .error failure => return .error failure
    | .ok condition =>
      match ← doDocument ownership formatTerm bodySyntax with
      | .error failure => return .error failure
      | .ok none => return .ok none
      | .ok (some body) =>
        return .ok (some (Doc.text "while " ++ condition ++ Doc.text " do" ++
          Doc.nest 2 (Doc.hard ++ body)))
  if stx.isOfKind ``Lean.Parser.Term.doUnless ||
      stx.isOfKind ``Lean.Parser.Term.doFor ||
      stx.isOfKind ``Lean.Parser.Term.doRepeat ||
      stx.isOfKind ``Lean.Parser.Term.doNested then
    let args := stx.getArgs
    let some sequenceIndex := args.findIdx? fun child =>
      child.isOfKind ``Lean.Parser.Term.doSeq ||
        child.isOfKind ``Lean.Parser.Term.doSeqIndent ||
        child.isOfKind ``Lean.Parser.Term.doSeqBracketed | return .ok none
    let sequence := args[sequenceIndex]!
    match ← doDocument ownership formatTerm sequence with
    | .error failure => return .error failure
    | .ok none => return .ok none
    | .ok (some body) =>
      let headerTokens := (args.extract 0 sequenceIndex).foldl (init := #[]) fun tokens child =>
        tokens ++ Syntax.spellings child
      return .ok (some (Syntax.flat headerTokens ++ Doc.nest 2 (Doc.hard ++ body)))
  if stx.isOfKind ``Lean.Parser.Term.doRepeatUntil then
    let args := stx.getArgs
    let some bodySyntax := args[1]? | return .ok none
    let some conditionSyntax := args[3]? | return .ok none
    match ← doDocument ownership formatTerm bodySyntax with
    | .error failure => return .error failure
    | .ok none => return .ok none
    | .ok (some body) =>
      match ← termDocumentOrFlat formatTerm conditionSyntax with
      | .error failure => return .error failure
      | .ok condition =>
        return .ok (some (Doc.text "repeat" ++ Doc.nest 2 (Doc.hard ++ body) ++
          Doc.hard ++ Doc.text "until " ++ condition))
  if stx.isOfKind ``Lean.Parser.Term.doTry then
    let args := stx.getArgs
    let some bodySyntax := args[1]? | return .ok none
    match ← doDocument ownership formatTerm bodySyntax with
    | .error failure => return .error failure
    | .ok none => return .ok none
    | .ok (some body) =>
      let mut document := Doc.text "try" ++ Doc.nest 2 (Doc.hard ++ body)
      if let some catches := args[2]? then
        for catchSyntax in nonemptyChildren catches do
          if catchSyntax.isOfKind ``Lean.Parser.Term.doCatch then
            let catchArgs := catchSyntax.getArgs
            let some catchBodySyntax := catchArgs[4]? | return .ok none
            match ← doDocument ownership formatTerm catchBodySyntax with
            | .error failure => return .error failure
            | .ok none => return .ok none
            | .ok (some catchBody) =>
              let headerTokens := (catchArgs.extract 0 4).foldl (init := #[]) fun tokens child =>
                tokens ++ Syntax.spellings child
              document := document ++ Doc.hard ++ Syntax.flat headerTokens ++
                Doc.nest 2 (Doc.hard ++ catchBody)
          else if catchSyntax.isOfKind ``Lean.Parser.Term.doCatchMatch then
            let catchArgs := catchSyntax.getArgs
            let some alternatives := catchArgs[1]? | return .ok none
            document := document ++ Doc.hard ++ Doc.text "catch"
            for alternative in nonemptyChildren alternatives do
              if alternative.isOfKind ``Lean.Parser.Term.matchAlt then
                match ← matchAlternativeDocument ownership
                    (doDocument ownership formatTerm) alternative with
                | .error failure => return .error failure
                | .ok none => return .ok none
                | .ok (some value) => document := document ++ Doc.hard ++ value
              else
                for nested in nonemptyChildren alternative do
                  match ← matchAlternativeDocument ownership
                      (doDocument ownership formatTerm) nested with
                  | .error failure => return .error failure
                  | .ok none => return .ok none
                  | .ok (some value) => document := document ++ Doc.hard ++ value
          else return .ok none
      if let some finallyPart := args[3]? then
        if let some finallySyntax := nonemptyChildren finallyPart |>.find?
            (fun child => child.isOfKind ``Lean.Parser.Term.doFinally) then
          let some finallyBodySyntax := finallySyntax.getArgs[1]? | return .ok none
          match ← doDocument ownership formatTerm finallyBodySyntax with
          | .error failure => return .error failure
          | .ok none => return .ok none
          | .ok (some finallyBody) =>
            document := document ++ Doc.hard ++ Doc.text "finally" ++
              Doc.nest 2 (Doc.hard ++ finallyBody)
      return .ok (some document)
  if stx.isOfKind ``Lean.Parser.Term.doLetArrow ||
      stx.isOfKind ``Lean.Parser.Term.doReassignArrow then
    return ← arrowDocument formatTerm (doDocument ownership formatTerm) stx
  if stx.isOfKind ``Lean.Parser.Term.doReturn then
    let args := nonemptyChildren stx
    if args.size == 1 then return .ok (some (Doc.text "return"))
    match ← wrappedTerm formatTerm args[args.size - 1]! with
    | .ok (some value) =>
      -- `doReturn` uses `checkLineEq`: the value must begin on the keyword's line. Nest the value at
      -- its actual post-keyword column so any internal record/collection breaks remain relative to
      -- the value rather than to the enclosing `do` item.
      return .ok (some (Doc.text "return" ++ Doc.nest 7 (Doc.text " " ++ value)))
    | .ok none => return .ok none
    | .error failure => return .error failure
  if stx.isOfKind ``Lean.Parser.Term.doDbgTrace ||
      stx.isOfKind ``Lean.Parser.Term.doIdbg ||
      stx.isOfKind ``Lean.Parser.Term.doAssert ||
      stx.isOfKind ``Lean.Parser.Term.doDebugAssert then
    let args := nonemptyChildren stx
    let some valueSyntax := args.back? | return .ok none
    match ← termDocumentOrFlat formatTerm valueSyntax with
    | .error failure => return .error failure
    | .ok value =>
      let prefixTokens := (args.extract 0 (args.size - 1)).foldl (init := #[]) fun tokens child =>
        tokens ++ Syntax.spellings child
      return .ok (some (Doc.group <| Syntax.flat prefixTokens ++
        Doc.nest 2 (Doc.line " " ++ value)))
  if stx.isOfKind ``Lean.Parser.Term.doContinue ||
      stx.isOfKind ``Lean.Parser.Term.doBreak then
    return .ok (some (Syntax.flat (Syntax.spellings stx)))
  if stx.isOfKind ``Lean.Parser.Term.doExpr then
    let args := nonemptyChildren stx
    let some valueSyntax := args.back? | return .ok none
    match ← wrappedTerm formatTerm valueSyntax with
    | .ok (some value) => return .ok (some value)
    | .ok none => return .ok none
    | .error failure => return .error failure
  if stx.isOfKind ``Lean.Parser.Term.doLet ||
      stx.isOfKind ``Lean.Parser.Term.doReassign ||
      stx.isOfKind ``Lean.Parser.Term.doHave then
    return ← assignmentDocument formatTerm stx
  if stx.isOfKind ``Lean.Parser.Term.doLetRec then
    return .ok (some (Syntax.flat (Syntax.spellings stx)))
  if stx.getKind == Lean.nullKind || stx.getKind == Lean.groupKind then
    let mut documents := #[]
    for nested in nonemptyChildren stx do
      match ← doDocument ownership formatTerm nested with
      | .ok (some document) => documents := documents.push document
      | .error failure => return .error failure
      | .ok none =>
        match ← formatTerm nested with
        | .ok (some document) => documents := documents.push document
        | .error failure => return .error failure
        | .ok none => return .ok none
    if documents.isEmpty then return .ok none
    return .ok (some (join documents (Doc.text " ")))
  match CoreSurface.owner (← Lean.getEnv) (.named `doElem) stx.getKind with
  | .extension =>
    return (← Formatter.registeredBoundary ownership (.named `doElem) stx).map fun formatted =>
      some formatted.document
  | _ => pure ()
  return .ok none

/-- Compose an actual `by` term from its tactic tree without delegating the closed block root. -/
def document (ownership : CommentOwnership) (formatTerm : TermDocument) (stx : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure (Option Doc)) := do
  if stx.isOfKind ``Lean.Parser.Term.do then
    let children := nonemptyChildren stx
    let some sequence := children.back? | return .ok none
    match ← doDocument ownership formatTerm sequence with
    | .ok (some body) => return .ok (some (Doc.text "do" ++ Doc.nest 2 (Doc.hard ++ body)))
    | .ok none => return .ok none
    | .error failure => return .error failure
  if !stx.isOfKind ``Lean.Parser.Term.byTactic then return .ok none
  let children := nonemptyChildren stx
  let some sequence := children.back? | return .ok none
  match ← tacticDocument ownership formatTerm sequence with
  | .ok (some body) =>
    return .ok (some (Doc.group (Doc.text "by" ++ Doc.nest 2 (Doc.line " " ++ body))))
  | .ok none => return .ok none
  | .error failure => return .error failure

end LeanFmt.Internal.Formatter.Block
