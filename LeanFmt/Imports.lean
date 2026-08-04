/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- The lossless module-header model and the import rules that read it.

Two facts this module rests on:

  1. **The surface header is not the abstract import list.** `Lean.parseImports'` prepends two
     synthesized `Init` imports on an ordinary file, a `prelude` marker suppresses them, and it drops
     every source range, comment, and modifier spelling (measured). So
     an import rule cannot count occurrences in `parseImports'.imports`; it must read the *written*
     header. This module reads it by parsing the header to `Lean.Syntax` — which builds an empty
     environment and is not a frontend run — and dispatching on the header grammar's node kinds
     (`Lean/Parser/Module/Syntax.lean:16-29`): `moduleTk`, `«prelude»`, `«import»`, and inside an
     import the `«public»`/`«meta»`/`«all»` modifier nodes.

  2. **Redundancy is a graph finding a pure rule cannot produce.** A `RuleImpl` is IO-free
     (`Rules.lean:17-19`) and cannot fetch a Lake facet, so import analysis is not part of the
     linear-tier `Facts`/`RuleImpl` engine at all — header facts (which the syntax projection drops)
     are orthogonal to the `source ≤ syntax ≤ semantic` chain. `duplicateFindings`/`orderFindings` are
     pure over the header model; `redundantFindings` is pure over the header model *plus* a transitive
     closure the caller fetched from the graph (`Project`), never from inside a rule.

Everything here indexes the normalized source (`raw.crlfToLf`), the one coordinate system every
finding, projection, and digest in the product shares (`AGENTS.md`). -/

import all LeanFmt.ArtifactModel
import all LeanFmt.LosslessSource

import Lean.Parser.Module

namespace LeanFmt.Internal.Imports

open LeanFmt.Internal (Finding Fix Edit Applicability Severity SourceRange)

/-- The organizer's header layout (`import-layout`).

`grouped` (the default) is the conservative rewrite: duplicates removed and each
blank-line/comment-delimited group sorted, no line ever crossing a group boundary. `canonical`
is the kan-proofs header style: imports re-bucketed by modifier (`public import`,
`public meta import`, `import all`, `import`, `meta import` — each `meta` variant directly
after its non-`meta` counterpart), each bucket internally ordered by prefix sub-block
(`import-groups`, then everything else) and alphabetically within a sub-block. Blank lines
separate buckets only; sub-blocks are contiguous — that is the kan-proofs script's pinned
behavior (its own test suite keeps a contiguous Lean/Mathlib/local run unchanged). `canonical`
moves lines across blank-line boundaries by design, which is why it is opt-in. The type lives here, not in `Config`, because the bucket order *is* the layout:
the module that implements both layouts owns the decision. -/
inductive ImportLayout where
  | grouped
  | canonical
  deriving BEq, Lean.ToJson, Lean.FromJson

instance : ToString ImportLayout where
  toString
    | .grouped => "grouped"
    | .canonical => "canonical"

/-- The default sub-block prefixes for the canonical layout (`import-groups`): the Lean and
Mathlib ecosystems each get a leading sub-block inside every bucket, everything else trails.
The constant is shared by `Config`'s field default and its `resolve`, so the two cannot drift. -/
def defaultImportGroups : Array String :=
  #["Lean", "Mathlib"]

/-- Bytes `[start, stop)` of `s` as a string, indexing the normalized UTF-8 (`Printer.sliceNormalized`
uses the same codec). Every offset here is a parser position, so it lies on a codepoint boundary. -/
private def slice (s : String) (start stop : Nat) : String :=
  if stop <= start then "" else (String.fromUTF8? (s.toUTF8.extract start stop)).getD s

/-! ## The lossless header model -/

/-- One written `import` statement, exactly as the surface text spells it.

The modifier flags are the presence of the `«public»`/`«meta»`/`«all»` child nodes, not a
re-derivation from the abstract `Import` — so `import all A` and `import A`, or `meta import A` and
`import A`, are different statements, which is what makes them *not* duplicates.
`isExported` folds in the `module`-marker interaction the surface
keyword alone does not carry: a `public import` is exported, a plain import is exported iff the file
has no `module` marker (measured). -/
structure ImportStmt where
  «module» : Lean.Name
  importAll : Bool
  isMeta : Bool
  isPublic : Bool
  isExported : Bool
  /-- `[first leaf start, last leaf stop)`: the import's own bytes, no trivia. -/
  range : SourceRange
  /-- `[line start, next line start)`: the whole physical line(s) the statement occupies, including its
  trailing newline. This is what a dedup fix deletes, and only when it contains nothing but the
  statement (no shared comment). -/
  lineRange : SourceRange
  deriving Inhabited, Repr

/-- The written header: the `module` marker, the imports in source order, and the header's end. Phantom
`Init` never appears here — this is the surface text, and `Init` is synthesized past the parser. -/
structure HeaderModel where
  hasModule : Bool
  hasPrelude : Bool
  imports : Array ImportStmt
  headerStop : Nat
  deriving Inhabited, Repr

/-! ## Parsing the surface header -/

/-- Byte range of every original leaf beneath `stx`, folded to `(min start, max stop)`, plus whether a
descendant node of `kind` is present. Returns `none` if any leaf lacks a position (partial syntax),
which cannot happen on an accepted header the parser produced without messages. -/
private partial def leafSpan (stx : Lean.Syntax) : Option (Nat × Nat) :=
  match stx with
  | .missing => none
  | .node _ _ args =>
    args.foldl (init := none) fun acc arg =>
      match acc, leafSpan arg with
      | some (a, b), some (c, d) => some (Nat.min a c, Nat.max b d)
      | some s, none => some s
      | none, other => other
  | .atom info _ | .ident info _ _ _ =>
    match info with
    | .original _ pos _ endPos => some (pos.byteIdx, endPos.byteIdx)
    | _ => none

/-- Whether `stx` contains a descendant node of the given kind — how a modifier (`«all»`, `«meta»`,
`«public»`) is detected. -/
private partial def hasKind (stx : Lean.Syntax) (kind : Lean.SyntaxNodeKind) : Bool :=
  match stx with
  | .node _ k args => k == kind || args.any (hasKind · kind)
  | _ => false

/-- The module `Name` of an `«import»` node: its identifier leaf (the last leaf, an ident). -/
private partial def identName? (stx : Lean.Syntax) : Option Lean.Name :=
  match stx with
  | .ident _ _ name _ => some name
  | .node _ _ args => args.foldl (init := none) fun acc arg => acc <|> identName? arg
  | _ => none

/-- The `[line start, next line start)` of a byte span in `normalized`. Line start is the byte after
the previous `\n` (or 0); next line start is the byte after the span's own line's `\n` (or end of
file). Used for the dedup fix and the organizer. -/
private def lineExtent (normalized : String) (start stop : Nat) : SourceRange :=
  Id.run do
    let bytes := normalized.toUTF8
    let mut lineStart := start
    while lineStart > 0 && bytes.get! (lineStart - 1) != 0x0a do
      lineStart := lineStart - 1
    let mut lineStop := stop
    while lineStop < bytes.size && bytes.get! lineStop != 0x0a do
      lineStop := lineStop + 1
    if lineStop < bytes.size then
      lineStop := lineStop + 1 -- include the newline
    return { start := lineStart, stop := lineStop }

/-- Every `«import»` node in the header, in source order. -/
private partial def importNodes (stx : Lean.Syntax) (acc : Array Lean.Syntax) : Array Lean.Syntax :=
  match stx with
  | .node _ kind args =>
    if kind == ``Lean.Parser.Module.«import» then acc.push stx
    else args.foldl (init := acc) fun acc arg => importNodes arg acc
  | _ => acc

private def hasNodeOfKind (stx : Lean.Syntax) (kind : Lean.SyntaxNodeKind) : Bool :=
  hasKind stx kind

/-- Parse the surface header of `normalized` into the model, or `none` if the header parser emits
any message. Any message is a refusal: on an accepted module the header log is empty, and a partial
parse would fabricate positions a rule must not read. `headerStop` is the parser's own post-header
position (`state.pos`), so the caller need not build a `LosslessSource` to supply it. -/
def parseHeaderModel (normalized : String) : IO (Option HeaderModel) := do
  let (stx, state, messages) ←
    Lean.Parser.parseHeader (Lean.Parser.mkInputContext normalized "<header>")
  if !messages.toList.isEmpty then
    return none
  let headerStop := state.pos.byteIdx
  let raw := stx.raw
  if raw.getKind != ``Lean.Parser.Module.header then
    return none
  let hasModule := hasNodeOfKind raw ``Lean.Parser.Module.moduleTk
  let hasPrelude := hasNodeOfKind raw ``Lean.Parser.Module.«prelude»
  let nodes := importNodes raw #[]
  let mut imports : Array ImportStmt := #[]
  for node in nodes do
    let some (start, stop) := leafSpan node | return none
    let some name := identName? node | return none
    let importAll := hasKind node ``Lean.Parser.Module.«all»
    let isMeta := hasKind node ``Lean.Parser.Module.«meta»
    let isPublic := hasKind node ``Lean.Parser.Module.«public»
    imports :=
      imports.push
        {
          «module» := name
          importAll,
          isMeta,
          isPublic
          isExported := isPublic || !hasModule
          range := { start, stop }
          lineRange := lineExtent normalized start stop }
  return some { hasModule, hasPrelude, imports, headerStop }

/-! ## FMT003 — duplicate import -/

/-- Whether two written imports are the same statement: same module and the same exposure. A differing
`all`/`meta`/exported flag makes them distinct imports that expose different data, never duplicates. -/
private def sameImport (a b : ImportStmt) : Bool :=
  a.module == b.module && a.importAll == b.importAll && a.isMeta == b.isMeta &&
    a.isExported == b.isExported

/-- Whether `range`'s line span in `normalized` holds nothing but the import — no comment, no second
statement — so deleting the whole line is a safe edit that cannot drop a comment. -/
private def lineIsSolelyImport (normalized : String) (stmt : ImportStmt) : Bool :=
  let before := slice normalized stmt.lineRange.start stmt.range.start
  let after := slice normalized stmt.range.stop stmt.lineRange.stop
  before.all (·.isWhitespace) && after.all (·.isWhitespace)

/-- FMT003: each written import after the first occurrence of the same statement is a duplicate.

The fix deletes the *later* line (`.safe`) — the surviving first occurrence keeps the exact ordered
header the environment replays, and a repeated identical import is an elaboration no-op (measured).
The fix is emitted only when the duplicate's line holds nothing but
the import; otherwise the finding is report-only so no comment is dropped. -/
def duplicateFindings (header : HeaderModel) (normalized : String) : Array Finding :=
  Id.run do
    let mut findings : Array Finding := #[]
    for h : i in [0:header.imports.size]do
      let stmt := header.imports[i]
      let isDup :=
        (List.range i).any fun j =>
          match header.imports[j]? with
          | some earlier => sameImport earlier stmt
          | none => false
      if isDup then
        let fix? : Option Fix :=
          if lineIsSolelyImport normalized stmt then
            some
              { applicability := .safe, edits := #[{ range := stmt.lineRange, replacement := "" }] }
          else none
        findings :=
          findings.push
            {
              code := "FMT003"
              severity := .warning
              message := s!"duplicate import of {stmt.module}"
              range := stmt.range
              fix? }
    return findings

/-- The modifier bucket of an import: `public` before non-`public`, `all` before plain, `meta`
immediately after its non-`meta` counterpart. -/
private def bucketRank (stmt : ImportStmt) : Nat :=
  (if stmt.isPublic then 0 else 4) + (if stmt.importAll then 0 else 2) +
    (if stmt.isMeta then 1 else 0)

/-- The sub-block of `module` within a bucket: the index of the first `groups` prefix it matches
(`P` matches `P` itself and every `P.…`), or `groups.size` — the trailing "everything else"
sub-block — when none does. -/
private def subblockIndex (groups : Array String) (module : Lean.Name) : Nat :=
  Id.run do
    let s := module.toString
    for h : i in [0:groups.size]do
      let grp := groups[i]
      if s == grp || s.startsWith (grp ++ ".") then
        return i
    return groups.size

/-! ## FMT005 — non-canonical import order within a group -/

/-- Whether two adjacent imports are separated by a blank line or a comment in `normalized` — the
boundary between two organization *groups*, which the canonical order never crosses: blank-line
groups are organization. -/
private def groupBreakBetween (normalized : String) (a b : ImportStmt) : Bool :=
  let gap := slice normalized a.range.stop b.range.start
  let newlines := gap.foldl (fun n c => if c == '\n' then n + 1 else n) 0
  newlines > 1 || gap.any (fun c => !c.isWhitespace)

/-- FMT005 under `grouped`: within a maximal run of imports uninterrupted by a blank line or
comment, the module names are not in ascending order. Under `canonical`: the whole header follows
the organizer's order key — modifier bucket, then prefix sub-block, then module path — across
blank lines (they are bucket boundaries, not order resets), stopping only at comments, which end
the organizer's canonical region too. Reported at the first out-of-order import; report-only,
because reordering imports is observable to elaboration — the canonical rewrite is delivered
only through the opt-in organizer, never an unattended `fix`. -/
def orderFindings (header : HeaderModel) (normalized : String) (layout : ImportLayout := .grouped)
    (groups : Array String := defaultImportGroups) : Array Finding :=
  Id.run do
    let before := fun (a b : ImportStmt) =>
      let (ab, as_, am) := (bucketRank a, subblockIndex groups a.module, a.module.toString)
      let (bb, bs, bm) := (bucketRank b, subblockIndex groups b.module, b.module.toString)
      ab < bb || (ab == bb && (as_ < bs || (as_ == bs && am < bm)))
    let mut findings : Array Finding := #[]
    for i in [1:header.imports.size]do
      let prev := header.imports[i - 1]!
      let cur := header.imports[i]!
      let outOfOrder :=
        match layout with
        | .grouped =>
          !groupBreakBetween normalized prev cur && cur.module.toString < prev.module.toString
        | .canonical =>
          -- A comment in the gap ends the canonical region (and this check); a blank-only gap is a
          -- bucket boundary the order crosses.
          let gap := slice normalized prev.range.stop cur.range.start
          gap.all Char.isWhitespace && before cur prev
      if outOfOrder then
        findings :=
          findings.push
            {
              code := "FMT005"
              severity := .warning
              message := s!"import {cur.module} is out of order (after {prev.module})"
              range := cur.range
              fix? := none }
    return findings

/-! ## FMT004 — redundant import (graph-validated, report-only, withholding)

The transitive closure is supplied by the caller (`Project`), which fetched it from the shared no-build
Lake graph. It maps each written import's module to the set of modules that import transitively pulls
in. A rule cannot fetch it (`Rules.lean:17-19`); this function is pure over the fetched facts. -/

/-- Whether `stmt` may be *reported* as a redundancy candidate at all. `import all`, `meta import`, and
a re-exported `public import` are **withheld**: reachability cannot reason about the private data, IR,
or downstream re-export they carry. Only plain, non-re-exported imports
are eligible. -/
def redundancyEligible (header : HeaderModel) (stmt : ImportStmt) : Bool :=
  !stmt.importAll && !stmt.isMeta && !(header.hasModule && stmt.isExported)

/-- FMT004: a plain written import that another written import already makes available is a
redundancy candidate. `covers outer inner` answers whether importing `outer` brings `inner` with it;
the caller owns what an unresolvable graph answers there. Report-only always — reachability is
necessary, not sufficient, for safe removal. Duplicates are excluded (they are FMT003's). Returns
the findings and the withheld count (candidates skipped by `redundancyEligible`). -/
def redundantFindings (header : HeaderModel) (covers : Lean.Name → Lean.Name → Bool) :
    Array Finding × Nat :=
  Id.run do
    let mut findings : Array Finding := #[]
    let mut withheld := 0
    for h : i in [0:header.imports.size]do
      let stmt := header.imports[i]
      -- Skip a literal duplicate: FMT003 owns it, not redundancy.
      let isDup :=
        (List.range i).any fun j =>
          match header.imports[j]? with
          | some earlier => sameImport earlier stmt
          | none => false
      if isDup then
        continue
      -- Is this module transitively pulled in by some *other* written import?
      let coveredBy :=
        header.imports.findIdx? fun other =>
          other.module != stmt.module && covers other.module stmt.module
      match coveredBy with
      | none =>
        pure ()
      | some j =>
        if redundancyEligible header stmt then
          findings :=
            findings.push
              {
                code := "FMT004"
                severity := .warning
                message :=
                  s!"import {stmt.module} is redundant: transitively available via \
            {header.imports[j]!.module}; verify before removing"
                range := stmt.range
                fix? := none }
        else
          withheld := withheld + 1
    return (findings, withheld)

/-! ## The canonical layout (`import-layout = "canonical"`)

The kan-proofs header style: one rewrite of the whole import region into modifier buckets,
prefix sub-blocks, and alphabetical order. Unlike `grouped`, lines move across blank-line
boundaries, so the safety rule is inverted: anything the reorder cannot account for (a block
comment, non-comment trailing text) refuses the file outright, and a standalone comment line
*ends* the region — imports below it are body text and stay untouched. -/

/-- One import in the canonical region, paired with the trailing `--` comment its line carried
(e.g. `-- shake: keep`), which rides with the import when the sort moves it. -/
private structure CanonicalImport where
  stmt : ImportStmt
  comment? : Option String := none
  deriving Inhabited

/-- The position of the `\n` ending `pos`'s line (or end of file), excluding the newline. -/
private def lineEnd (normalized : String) (pos : Nat) : Nat :=
  Id.run do
    let bytes := normalized.toUTF8
    let mut i := pos
    while i < bytes.size && bytes.get! i != 0x0a do
      i := i + 1
    return i

/-- The statement's source bytes with every whitespace run collapsed to one space: canonical
single-spacing (and one physical line) without re-spelling the module name, so escaped
identifiers (`import «weird»`) survive verbatim. -/
private def collapseSpaces (s : String) : String :=
  Id.run do
    let mut words : List String := []
    let mut cur := ""
    for c in s do
      if c.isWhitespace then
        if !cur.isEmpty then
          words := cur :: words;
          cur := ""
      else
        cur := cur.push c
    if !cur.isEmpty then
      words := cur :: words
    return String.intercalate " " words.reverse

/-- The leading run of imports the canonical rewrite governs, each with its trailing `--`
comment, plus the end-of-line position of the run's last import (the region's stop).

A standalone comment line between imports ends the run — everything below is preserved as
body, and the result is still idempotent. `none` refuses the whole file: a line whose trailing
text is not a `--` comment (a block comment that may span lines, or a second statement) cannot
be reordered without risking dropped text. -/
private def canonicalRegion? (header : HeaderModel) (normalized : String) :
    Option (Array CanonicalImport × Nat) :=
  Id.run do
    let mut entries : Array CanonicalImport := #[]
    let mut prevLineEnd : Nat := 0
    for h : i in [0:header.imports.size]do
      let stmt := header.imports[i]
      if i > 0 then
        let gap := slice normalized prevLineEnd stmt.lineRange.start
        if gap.any (!·.isWhitespace) then
          return some (entries, prevLineEnd)
      let eol := lineEnd normalized stmt.range.stop
      let trailing := (slice normalized stmt.range.stop eol).trimAscii.toString
      -- `return none`, not `none`: `Id α` unfolds to `α`, so a bare `none` would bind
      -- `comment? := none` and silently drop the comment instead of refusing.
      let comment? : Option String ←
        if trailing.isEmpty then
          pure none
        else if trailing.startsWith "--" then
          pure (some trailing)
        else
          return none
      entries := entries.push { stmt, comment? }
      prevLineEnd := eol
    return some (entries, prevLineEnd)

/-- Drop whole leading blank lines from `s` (the text after the import region); the first line
with any non-whitespace content is kept intact, indentation included. -/
private def dropLeadingBlankLines (s : String) : String :=
  let rec loop : List String → List String
    | l :: rest => if l.all Char.isWhitespace then loop rest else l :: rest
    | [] => []
  String.intercalate "\n" (loop (s.splitOn "\n"))

/-- The canonical header text: the import region rebuilt as modifier buckets of prefix
sub-blocks, duplicates removed, trailing comments retained, everything outside the region —
copyright block, `module`/`prelude` markers, body — preserved verbatim apart from normalizing
to exactly one blank line on each side of the region.

`none` is a refusal (`canonicalRegion?`): the caller leaves the file unchanged. A duplicate
whose line carried a trailing comment transfers that comment to the surviving occurrence —
dedup must not silently delete a `shake: keep`. -/
def canonicalize (header : HeaderModel) (normalized : String)
    (groups : Array String := defaultImportGroups) : Option String :=
  Id.run do
    if header.imports.isEmpty then
      return none
    let some (entries, regionStop) := canonicalRegion? header normalized | return none
    -- Dedup (first occurrence survives, inheriting a dropped duplicate's comment if it had none).
    let mut kept : Array CanonicalImport := #[]
    for entry in entries do
      match kept.findIdx? fun k => sameImport k.stmt entry.stmt with
      | none =>
        kept := kept.push entry
      | some j =>
        if kept[j]!.comment?.isNone then
          if let some comment := entry.comment? then
            kept := kept.set! j { kept[j]! with comment? := some comment }
    -- Sort by bucket, then sub-block, then module path; the key is total on survivors because
    -- same-bucket duplicates are already gone.
    let sorted :=
      kept.qsort fun a b =>
        let ra := bucketRank a.stmt
        let rb := bucketRank b.stmt
        if ra != rb then ra < rb
        else
          let sa := subblockIndex groups a.stmt.module
          let sb := subblockIndex groups b.stmt.module
          if sa != sb then sa < sb else a.stmt.module.toString < b.stmt.module.toString
    -- Emit: one blank line where the modifier bucket changes. Sub-blocks within a bucket stay
    -- contiguous (script parity); the sub-block index only orders, it does not separate.
    let mut lines : Array String := #[]
    let mut prevRank? : Option Nat := none
    for entry in sorted do
      let rank := bucketRank entry.stmt
      if prevRank?.isSome && prevRank? != some rank then
        lines := lines.push ""
      let text := collapseSpaces (slice normalized entry.stmt.range.start entry.stmt.range.stop)
      lines :=
        lines.push <|
          match entry.comment? with
          | some comment => text ++ " " ++ comment
          | none => text
      prevRank? := some rank
    -- Reassemble: verbatim text before the region, the rebuilt region, the body with its leading
    -- blank lines normalized to one.
    let before := (slice normalized 0 header.imports[0]!.lineRange.start).trimAsciiEnd.toString
    let lead := if before.isEmpty then "" else before ++ "\n\n"
    let body := dropLeadingBlankLines (slice normalized regionStop normalized.utf8ByteSize)
    let suffix :=
      if body.trimAscii.isEmpty then (if normalized.endsWith "\n" then "\n" else "")
      else "\n\n" ++ body
    return lead ++ String.intercalate "\n" lines.toList ++ suffix

/-! ## The organizer -/

/-- The `grouped` layout: the original header with duplicates removed and each blank-line/
comment-delimited group's imports sorted by module name, everything else — the `module` marker,
`prelude`, modifiers, comments, and group boundaries — preserved. -/
private def organizeGrouped (header : HeaderModel) (normalized : String) : String :=
  Id.run do
    if header.imports.isEmpty then
      return normalized
    -- Partition imports into groups separated by a blank line or comment.
    let mut groups : Array (Array Nat) := #[]
    let mut current : Array Nat := #[]
    for i in [0:header.imports.size]do
      if i > 0 && groupBreakBetween normalized header.imports[i - 1]! header.imports[i]! then
        groups := groups.push current
        current := #[]
      current := current.push i
    groups := groups.push current
    -- Within each group: drop later duplicates, then sort surviving lines by module name.
    let mut newImportRegion : String := ""
    let firstStart := header.imports[0]!.range.start
    let lastStop := header.imports[header.imports.size - 1]!.range.stop
    -- Rebuild the region [firstStart, lastStop) group by group, preserving the gaps between groups.
    let mut cursor := firstStart
    for g in [0:groups.size]do
      let group := groups[g]!
      -- Keep, in written order, the first occurrence of each distinct statement.
      let mut kept : Array Nat := #[]
      for idx in group do
        let stmt := header.imports[idx]!
        let already := kept.any fun k => sameImport header.imports[k]! stmt
        unless already do
          kept := kept.push idx
      -- Sort kept lines by module name (stable on ties, which duplicates already removed).
      let sorted :=
        kept.qsort fun a b =>
          header.imports[a]!.module.toString < header.imports[b]!.module.toString
      -- Emit each import's own line text (its statement bytes), newline-separated.
      let lines :=
        sorted.map fun idx =>
          slice normalized header.imports[idx]!.range.start header.imports[idx]!.range.stop
      -- The gap before this group (from cursor to the group's first import start) is preserved verbatim.
      let groupStart := header.imports[group[0]!]!.range.start
      newImportRegion :=
        newImportRegion ++ slice normalized cursor groupStart ++
          String.intercalate "\n" lines.toList
      cursor := header.imports[group[group.size - 1]!]!.range.stop
    -- Reassemble: everything before the first import, the rebuilt region, everything after the last.
    return slice normalized 0 firstStart ++ newImportRegion ++
        slice normalized lastStop normalized.utf8ByteSize

/-- The canonical header text under `layout`. This is the one operation the CLI and
LSP "organize imports" capability calls; it exposes no graph internals, only text in, text out.

`grouped` (the default) is `organizeGrouped`: sort within each blank-line/comment group, never
across one. `canonical` is `canonicalize`: the whole region re-bucketed by modifier and prefix
sub-block. A `canonical` refusal (a block comment or non-comment trailing text in the region)
leaves the file unchanged rather than falling back — a half-applied style is worse than none.

Redundancy (FMT004) is **not** removed here — it is report-only, so the organizer surfaces candidates
through `redundantFindings` but never deletes them. -/
def organize (header : HeaderModel) (normalized : String) (layout : ImportLayout := .grouped)
    (groups : Array String := defaultImportGroups) : String :=
  match layout with
  | .grouped => organizeGrouped header normalized
  | .canonical => (canonicalize header normalized groups).getD normalized

/-- The canonical-header candidate `organize` would write for `source`, or `none` when the
header needs no change (or has no parseable header model).

One definition for the organizer's candidate loop and the result cache's live set: a stored
rejection verdict has a consumer exactly while the header on disk still computes to this
candidate, so the two callers must never drift. `layout` and `groups` come from the target's
discovered configuration; they are part of the candidate bytes, so a configuration change
invalidates stored verdicts without touching cache identity. -/
def organizeCandidate? (source : String) (layout : ImportLayout := .grouped)
    (groups : Array String := defaultImportGroups) : IO (Option String) := do
  let (normalized, lineEndings) := LosslessSource.normalize source
  match ← parseHeaderModel normalized with
  | none =>
    return none
  | some header =>
    let output := LosslessSource.denormalize (organize header normalized layout groups) lineEndings
    return (if output == source then none else some output)

end LeanFmt.Internal.Imports
