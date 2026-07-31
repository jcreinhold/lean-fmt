/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.LosslessSource

import Lean

/-! The wire form of a parsed module: one flat pre-order array, an interned kind table, one root per
command.

`Lean.Syntax` is a tree of boxed nodes. Here the same tree is `SyntaxEntry` values in pre-order,
each node carrying only how many children follow, so a subtree is a contiguous slice. That is what
lets `ofRecords` concatenate independently produced command trees by appending, and lets
`structurallyValid` check the whole array in one linear walk.

Commands arrive as separate `CommandArtifactRecord` values because the compiler plugin emits one per
command and async elaboration finishes them in any order. Ordering, interning, and compaction happen
here, once, after the module has succeeded.

Every offset indexes the normalized source, never the bytes on disk. -/

namespace LeanFmt.Internal

inductive EncodedSourceInfo where
  | none
  | original (leadingStart position endPosition trailingStop : Nat)
  | synthetic (position endPosition : Nat) (canonical : Bool)
  deriving Inhabited, BEq, Repr

inductive EncodedPreresolved where
  | «namespace» (name : Lean.Name)
  | decl (name : Lean.Name) (fields : List String)
  deriving Inhabited, BEq, Repr

inductive SyntaxEntry where
  | missing
  | node (info : EncodedSourceInfo) (kind : Nat) (children : Nat)
  | atom (info : EncodedSourceInfo) (value? : Option String)
  |
  ident (info : EncodedSourceInfo) (raw? : Option String) (value : Lean.Name)
    (preresolved : Array EncodedPreresolved)
  deriving Inhabited, BEq, Repr

structure SyntaxTree where
  kinds : Array Lean.Name
  entries : Array SyntaxEntry
  deriving Inhabited, BEq, Repr

structure SyntaxRoot where
  entry : Nat
  range : SourceRange
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

structure ModuleSyntax where
  kinds : Array Lean.Name
  entries : Array SyntaxEntry
  commands : Array SyntaxRoot
  terminal : Nat
  deriving Inhabited, BEq, Repr

private def jsonField (fields : Array Lean.Json) (index : Nat) : Except String Lean.Json :=
  match fields[index]? with
  | some field => .ok field
  | none => .error s!"missing field {index}"

private def jsonNat (json : Lean.Json) : Except String Nat :=
  Lean.fromJson? json

instance : Lean.ToJson EncodedSourceInfo where
  toJson
    | .none => .num 0
    | .original leadingStart position endPosition trailingStop =>
      .arr #[.num 1, .num leadingStart, .num position, .num endPosition, .num trailingStop]
    | .synthetic position endPosition canonical =>
      .arr #[.num 2, .num position, .num endPosition, .bool canonical]

instance : Lean.FromJson EncodedSourceInfo where
  fromJson? json := do
    if let .num 0 := json then
      return .none
    let fields ← json.getArr?
    match ← jsonNat (← jsonField fields 0) with
    | 1 =>
      let leadingStart ← jsonNat (← jsonField fields 1)
      let position ← jsonNat (← jsonField fields 2)
      let endPosition ← jsonNat (← jsonField fields 3)
      let trailingStop ← jsonNat (← jsonField fields 4)
      return .original leadingStart position endPosition trailingStop
    | 2 =>
      let position ← jsonNat (← jsonField fields 1)
      let endPosition ← jsonNat (← jsonField fields 2)
      let canonical ← Lean.fromJson? (← jsonField fields 3)
      return .synthetic position endPosition canonical
    | tag =>
      throw s!"unknown source-info tag {tag}"

instance : Lean.ToJson EncodedPreresolved where
  toJson
    | .namespace name => .arr #[.num 0, Lean.toJson name]
    | .decl name fields => .arr #[.num 1, Lean.toJson name, Lean.toJson fields]

instance : Lean.FromJson EncodedPreresolved where
  fromJson? json := do
    let fields ← json.getArr?
    match ← jsonNat (← jsonField fields 0) with
    | 0 =>
      return .namespace (← Lean.fromJson? (← jsonField fields 1))
    | 1 =>
      let name ← Lean.fromJson? (← jsonField fields 1)
      let declFields ← Lean.fromJson? (← jsonField fields 2)
      return .decl name declFields
    | tag =>
      throw s!"unknown preresolved tag {tag}"

instance : Lean.ToJson SyntaxEntry where
  toJson
    | .missing => .arr #[.num 0]
    | .node info kind children => .arr #[.num 1, Lean.toJson info, .num kind, .num children]
    | .atom info value? => .arr #[.num 2, Lean.toJson info, Lean.toJson value?]
    | .ident info raw? value preresolved =>
      .arr #[.num 3, Lean.toJson info, Lean.toJson raw?, Lean.toJson value, Lean.toJson preresolved]

instance : Lean.FromJson SyntaxEntry where
  fromJson? json := do
    let fields ← json.getArr?
    match ← jsonNat (← jsonField fields 0) with
    | 0 =>
      return .missing
    | 1 =>
      let info ← Lean.fromJson? (← jsonField fields 1)
      let kind ← jsonNat (← jsonField fields 2)
      let children ← jsonNat (← jsonField fields 3)
      return .node info kind children
    | 2 =>
      let info ← Lean.fromJson? (← jsonField fields 1)
      let value? ← Lean.fromJson? (← jsonField fields 2)
      return .atom info value?
    | 3 =>
      let info ← Lean.fromJson? (← jsonField fields 1)
      let raw? ← Lean.fromJson? (← jsonField fields 2)
      let value ← Lean.fromJson? (← jsonField fields 3)
      let preresolved ← Lean.fromJson? (← jsonField fields 4)
      return .ident info raw? value preresolved
    | tag =>
      throw s!"unknown syntax-entry tag {tag}"

instance : Lean.ToJson SyntaxTree where
  toJson tree := Lean.Json.mkObj [("k", Lean.toJson tree.kinds), ("e", Lean.toJson tree.entries)]

instance : Lean.FromJson SyntaxTree where
  fromJson? json :=
    return {
        kinds := ← json.getObjValAs? (Array Lean.Name) "k"
        entries := ← json.getObjValAs? (Array SyntaxEntry) "e" }

deriving instance Lean.ToJson for ModuleSyntax

deriving instance Lean.FromJson for ModuleSyntax

private def encodeInfo : Lean.SourceInfo → EncodedSourceInfo
  | .none => .none
  | .original leading position trailing endPosition =>
    .original leading.startPos.byteIdx position.byteIdx endPosition.byteIdx trailing.stopPos.byteIdx
  | .synthetic position endPosition canonical =>
    .synthetic position.byteIdx endPosition.byteIdx canonical

private structure SyntaxBuild where
  kinds : Array Lean.Name := #[]
  kindIndex : Std.HashMap Lean.Name Nat := { }
  entries : Array SyntaxEntry := #[]

private def SyntaxBuild.intern (build : SyntaxBuild) (kind : Lean.Name) : Nat × SyntaxBuild :=
  match build.kindIndex[kind]? with
  | some index => (index, build)
  | none =>
    let index := build.kinds.size
    (index,
      { build with
        kinds := build.kinds.push kind
        kindIndex := build.kindIndex.insert kind index })

private partial def encodeSyntax (stx : Lean.Syntax) (build : SyntaxBuild) : SyntaxBuild :=
  match stx with
  | .missing => { build with entries := build.entries.push .missing }
  | .node info kind children =>
    let (kind, build) := build.intern kind
    let build :=
      { build with entries := build.entries.push (.node (encodeInfo info) kind children.size) }
    children.foldl (init := build) fun build child => encodeSyntax child build
  | .atom info value =>
    let value? :=
      match info with
      | .original .. => none
      | _ => some value
    { build with entries := build.entries.push (.atom (encodeInfo info) value?) }
  | .ident info raw value preresolved =>
    let raw? :=
      match info with
      | .original .. => none
      | _ => some raw.toString
    let preresolved :=
      preresolved.toArray.map fun
        | .namespace name => EncodedPreresolved.namespace name
        | .decl name fields => .decl name fields
    { build with entries := build.entries.push (.ident (encodeInfo info) raw? value preresolved) }

def SyntaxTree.ofSyntax (stx : Lean.Syntax) : SyntaxTree :=
  let build := encodeSyntax stx { }
  { kinds := build.kinds, entries := build.entries }

private def rawPosition (offset : Nat) : String.Pos.Raw :=
  ⟨offset⟩

private def rawSubstring (source : String) (start stop : Nat) : Substring.Raw :=
  Substring.Raw.mk source (rawPosition start) (rawPosition stop)

private def EncodedSourceInfo.decode (source : String) : EncodedSourceInfo → Lean.SourceInfo
  | .none => .none
  | .original leadingStart position endPosition trailingStop =>
    .original (rawSubstring source leadingStart position) (rawPosition position)
      (rawSubstring source endPosition trailingStop) (rawPosition endPosition)
  | .synthetic position endPosition canonical =>
    .synthetic (rawPosition position) (rawPosition endPosition) canonical

private def EncodedSourceInfo.range? : EncodedSourceInfo → Option SourceRange
  | .none => Option.none
  | .original _ position endPosition _ | .synthetic position endPosition _ =>
    some ⟨position, endPosition⟩

private def sourceSlice (source : String) (range : SourceRange) : Except String String := do
  let bytes := source.toUTF8
  unless range.start <= range.stop && range.stop <= bytes.size do
    throw s!"syntax range {range.start}:{range.stop} exceeds {bytes.size} source bytes"
  return String.fromUTF8! (bytes.extract range.start range.stop)

private partial def decodeSyntax (source : String) (tree : SyntaxTree) (index : Nat) :
    Except String (Lean.Syntax × Nat) := do
  let some entry := tree.entries[index]? | throw s!"missing syntax entry {index}"
  match entry with
  | .missing =>
    return (.missing, index + 1)
  | .node info kindIndex childCount =>
    let some kind := tree.kinds[kindIndex]? | throw s!"missing syntax kind {kindIndex}"
    let mut children := #[]
    let mut cursor := index + 1
    for _ in [0:childCount]do
      let (child, next) ← decodeSyntax source tree cursor
      children := children.push child
      cursor := next
    return (.node (info.decode source) kind children, cursor)
  | .atom info value? =>
    let value ←
      match value? with
      | some value =>
        pure value
      | none =>
        let some range := info.range? | throw "source-backed atom has no range"
        sourceSlice source range
    return (.atom (info.decode source) value, index + 1)
  | .ident info raw? value preresolved =>
    let raw ←
      match raw? with
      | some raw =>
        pure raw.toRawSubstring
      | none =>
        let some range := info.range? | throw "source-backed identifier has no range"
        pure (rawSubstring source range.start range.stop)
    let preresolved :=
      preresolved.toList.map fun
        | .namespace name => Lean.Syntax.Preresolved.namespace name
        | .decl name fields => .decl name fields
    return (.ident (info.decode source) raw value preresolved, index + 1)

def SyntaxEntry.remapKind (mapping : Array Nat) : SyntaxEntry → Option SyntaxEntry
  | .node info kind children => return .node info (← mapping[kind]?) children
  | entry => some entry

private def infoValid (bytes : Nat) : EncodedSourceInfo → Bool
  | .none => true
  | .original leading position endPosition trailing =>
    leading <= position && position <= endPosition && endPosition <= trailing && trailing <= bytes
  | .synthetic position endPosition _ => position <= endPosition && endPosition <= bytes

private partial def validateTreeAt (kinds bytes : Nat) (entries : Array SyntaxEntry) (index : Nat) :
    Option Nat := do
  let entry ← entries[index]?
  match entry with
  | .missing =>
    some (index + 1)
  | .node info kind children =>
    guard <| kind < kinds && infoValid bytes info
    let mut cursor := index + 1
    for _ in [0:children]do
      cursor ← validateTreeAt kinds bytes entries cursor
    return cursor
  | .atom info _ | .ident info .. =>
    guard <| infoValid bytes info
    return index + 1

def SyntaxTree.structurallyValid (tree : SyntaxTree) (bytes : Nat) : Bool :=
  match validateTreeAt tree.kinds.size bytes tree.entries 0 with
  | some next => next == tree.entries.size
  | none => false

def SyntaxTree.range? (tree : SyntaxTree) : Option SourceRange :=
  Id.run do
    let mut range? : Option SourceRange := none
    for entry in tree.entries do
      let info :=
        match entry with
        | .node info .. | .atom info .. | .ident info .. => info
        | .missing => .none
      if let some range := info.range? then
        range? :=
          some <|
            match range? with
            | none => range
            | some current => ⟨min current.start range.start, max current.stop range.stop⟩
    return range?

def SyntaxTree.leadingStart? (tree : SyntaxTree) : Option Nat :=
  tree.entries.findSome? fun entry =>
    match entry with
    | .atom (.original leading ..) _ | .ident (.original leading ..) .. => some leading
    | .atom (.synthetic position ..) _ | .ident (.synthetic position ..) .. => some position
    | _ => none

structure CommandArtifactRecord where
  schema : String
  mainModule : String
  normalizedBytes : Nat
  normalizedDigest : Digest
  terminal : Bool
  tree : SyntaxTree
  deriving BEq, Repr, Lean.ToJson, Lean.FromJson

def commandArtifactSchema : String :=
  "lean-fmt.command-syntax.v1"

def CommandArtifactRecord.ofSyntax (mainModule normalized : String) (terminal : Bool)
    (stx : Lean.Syntax) : CommandArtifactRecord :=
  { schema := commandArtifactSchema
    mainModule
    normalizedBytes := normalized.utf8ByteSize
    normalizedDigest := Digest.ofString normalized
    terminal
    tree := SyntaxTree.ofSyntax stx }

def CommandArtifactRecord.structurallyValid (record : CommandArtifactRecord) : Bool :=
  record.schema == commandArtifactSchema && record.tree.structurallyValid record.normalizedBytes &&
      record.tree.leadingStart?.isSome &&
    record.tree.range?.isSome

private structure ModuleBuild where
  kinds : Array Lean.Name := #[]
  kindIndex : Std.HashMap Lean.Name Nat := { }
  entries : Array SyntaxEntry := #[]

private def ModuleBuild.internKind (build : ModuleBuild) (kind : Lean.Name) : Nat × ModuleBuild :=
  match build.kindIndex[kind]? with
  | some index => (index, build)
  | none =>
    let index := build.kinds.size
    (index,
      { build with
        kinds := build.kinds.push kind
        kindIndex := build.kindIndex.insert kind index })

private def ModuleBuild.appendTree (build : ModuleBuild) (tree : SyntaxTree) :
    Option (Nat × ModuleBuild) := do
  let mut build := build
  let mut mapping := #[]
  for kind in tree.kinds do
    let (index, next) := build.internKind kind
    mapping := mapping.push index
    build := next
  let root := build.entries.size
  let entries ← tree.entries.mapM (·.remapKind mapping)
  return (root, { build with entries := build.entries ++ entries })

private def recordOrder (left right : CommandArtifactRecord) : Bool :=
  left.tree.leadingStart?.getD 0 < right.tree.leadingStart?.getD 0

def ModuleSyntax.ofRecords (records : Array CommandArtifactRecord) : Except String ModuleSyntax :=
  do
  let records := records.qsort recordOrder
  let terminals := records.filter (·.terminal)
  unless terminals.size == 1 do
    throw s!"expected one terminal syntax record, got {terminals.size}"
  let ordinary := records.filter (!·.terminal)
  let mut build : ModuleBuild := { }
  let mut commands := #[]
  for record in ordinary do
    let root := build.entries.size
    let some (_, next) := build.appendTree record.tree | throw "invalid command kind mapping"
    build := next
    let some range := record.tree.range? | throw "command syntax has no range"
    commands := commands.push { entry := root, range }
  let some terminalRecord := terminals[0]? | throw "terminal syntax record disappeared"
  let terminal := build.entries.size
  let some (_, finalBuild) := build.appendTree terminalRecord.tree
    | throw "invalid terminal kind mapping"
  return { finalBuild with
      commands, terminal }

structure MaterializedSyntax where
  commands : Array Lean.Syntax
  terminal : Lean.Syntax

def ModuleSyntax.materialize (moduleData : ModuleSyntax) (source : String) :
    Except String MaterializedSyntax := do
  let tree : SyntaxTree := { kinds := moduleData.kinds, entries := moduleData.entries }
  let mut commands := #[]
  for root in moduleData.commands do
    let (command, _) ← decodeSyntax source tree root.entry
    commands := commands.push command
  let (terminal, terminalNext) ← decodeSyntax source tree moduleData.terminal
  unless terminalNext == moduleData.entries.size do
    throw "terminal syntax does not end at the artifact boundary"
  return { commands, terminal }

def ModuleSyntax.structurallyValid (moduleData : ModuleSyntax) (bytes : Nat) : Bool :=
  Id.run do
    let tree : SyntaxTree := { kinds := moduleData.kinds, entries := moduleData.entries }
    let mut cursor := 0
    let mut sourceStop := 0
    for root in moduleData.commands do
      unless
        root.entry == cursor && root.range.start <= root.range.stop && root.range.stop <= bytes &&
          sourceStop <= root.range.start do
        return false
      let some next := validateTreeAt moduleData.kinds.size bytes moduleData.entries cursor
        | return false
      cursor := next
      sourceStop := root.range.stop
    unless moduleData.terminal == cursor do
      return false
    let some terminalNext := validateTreeAt moduleData.kinds.size bytes moduleData.entries cursor
      | return false
    return terminalNext == tree.entries.size

end LeanFmt.Internal
