/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- The lossless module-header model and the import rules that read it.

`RIR-SPEC` (`docs/projects/ruff-09-import-rules/notes/01-semantics.md`) froze two facts this module
rests on:

  1. **The surface header is not the abstract import list.** `Lean.parseImports'` prepends two
     synthesized `Init` imports on an ordinary file, a `prelude` marker suppresses them, and it drops
     every source range, comment, and modifier spelling (measured, `evidence/01-semantics.txt`). So an
     import rule cannot count occurrences in `parseImports'.imports`; it must read the *written*
     header. This module reads it by parsing the header to `Lean.Syntax` — the same parse the printer
     already does (`Printer.lean:2030`), which builds an empty environment and is not a frontend run —
     and dispatching on the header grammar's node kinds
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

import Lean.Parser.Module

namespace LeanFmt.Internal.Imports

open LeanFmt.Internal (Finding Fix Edit Applicability Severity SourceRange)

/-- Bytes `[start, stop)` of `s` as a string, indexing the normalized UTF-8 (`Printer.sliceNormalized`
uses the same codec). Every offset here is a parser position, so it lies on a codepoint boundary. -/
private def slice (s : String) (start stop : Nat) : String :=
  if stop <= start then "" else (String.fromUTF8? (s.toUTF8.extract start stop)).getD s

/-! ## The lossless header model -/

/-- One written `import` statement, exactly as the surface text spells it.

The modifier flags are the `«public»`/`«meta»`/`«all»` child nodes' presence, not a re-derivation from
the abstract `Import` — so `import all A` and `import A`, or `meta import A` and `import A`, are two
different statements, which is what makes them *not* duplicates (`notes/01-semantics.md` §3).
`isExported` folds in the `module`-marker interaction the surface keyword alone does not carry: a
`public import` is exported, a plain import is exported iff the file has no `module` marker (measured,
`evidence/01-semantics.txt` §A). -/
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
`Init` never appears here — this is the surface text, and `Init` is synthesized past the parser
(`notes/01-semantics.md` §1a). -/
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
`«public»`) is detected, mirroring the printer's kind dispatch (`Printer.lean:1877-1885`). -/
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
private def lineExtent (normalized : String) (start stop : Nat) : SourceRange := Id.run do
  let bytes := normalized.toUTF8
  let mut lineStart := start
  while lineStart > 0 && bytes.get! (lineStart - 1) != 0x0a do
    lineStart := lineStart - 1
  let mut lineStop := stop
  while lineStop < bytes.size && bytes.get! lineStop != 0x0a do
    lineStop := lineStop + 1
  if lineStop < bytes.size then lineStop := lineStop + 1  -- include the newline
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

/-- Parse the surface header of `normalized` into the model, or `none` if the header parser emits any
message. Any message is a refusal, exactly as the printer refuses (`Printer.lean:2030-2033`): on an
accepted module the header log is empty, and a partial parse would fabricate positions a rule must not
read. `headerStop` is the parser's own post-header position (`state.pos`), so the caller need not build
a `LosslessSource` to supply it — this parse already knows where the header ends. -/
def parseHeaderModel (normalized : String) : IO (Option HeaderModel) := do
  let (stx, state, messages) ← Lean.Parser.parseHeader (Lean.Parser.mkInputContext normalized "<header>")
  if !messages.toList.isEmpty then return none
  let headerStop := state.pos.byteIdx
  let raw := stx.raw
  if raw.getKind != ``Lean.Parser.Module.header then return none
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
    imports := imports.push {
      «module» := name
      importAll, isMeta, isPublic
      isExported := isPublic || !hasModule
      range := { start, stop }
      lineRange := lineExtent normalized start stop
    }
  return some { hasModule, hasPrelude, imports, headerStop }

/-! ## FMT005 — duplicate import -/

/-- Whether two written imports are the same statement: same module and the same exposure. A differing
`all`/`meta`/exported flag makes them distinct imports that expose different data, never duplicates
(`notes/01-semantics.md` §3). -/
private def sameImport (a b : ImportStmt) : Bool :=
  a.module == b.module && a.importAll == b.importAll && a.isMeta == b.isMeta &&
    a.isExported == b.isExported

/-- Whether `range`'s line span in `normalized` holds nothing but the import — no comment, no second
statement — so deleting the whole line is a safe edit that cannot drop a comment. -/
private def lineIsSolelyImport (normalized : String) (stmt : ImportStmt) : Bool :=
  let before := slice normalized stmt.lineRange.start stmt.range.start
  let after := slice normalized stmt.range.stop stmt.lineRange.stop
  before.all (·.isWhitespace) && after.all (·.isWhitespace)

/-- FMT005: each written import after the first occurrence of the same statement is a duplicate.

The fix deletes the *later* line (`.safe`) — the surviving first occurrence keeps the exact ordered
header the environment replays, and a repeated identical import is an elaboration no-op (measured,
`evidence/01-semantics.txt` §B). The fix is emitted only when the duplicate's line holds nothing but
the import; otherwise the finding is report-only so no comment is dropped (`notes/01-semantics.md` §3,
"preserving any comment"). -/
def duplicateFindings (header : HeaderModel) (normalized : String) : Array Finding := Id.run do
  let mut findings : Array Finding := #[]
  for h : i in [0:header.imports.size] do
    let stmt := header.imports[i]
    let isDup := (List.range i).any fun j =>
      match header.imports[j]? with
      | some earlier => sameImport earlier stmt
      | none => false
    if isDup then
      let fix? : Option Fix :=
        if lineIsSolelyImport normalized stmt then
          some { applicability := .safe, edits := #[{ range := stmt.lineRange, replacement := "" }] }
        else none
      findings := findings.push {
        code := "FMT005"
        severity := .warning
        message := s!"duplicate import of {stmt.module}"
        range := stmt.range
        fix?
      }
  return findings

/-! ## FMT007 — non-canonical import order within a group -/

/-- Whether two adjacent imports are separated by a blank line or a comment in `normalized` — the
boundary between two organization *groups*, which the canonical order never crosses
(`notes/01-semantics.md` §3, matching `Printer.lean:1936-1941`: blank-line groups are organization). -/
private def groupBreakBetween (normalized : String) (a b : ImportStmt) : Bool :=
  let gap := slice normalized a.range.stop b.range.start
  let newlines := gap.foldl (fun n c => if c == '\n' then n + 1 else n) 0
  newlines > 1 || gap.any (fun c => !c.isWhitespace)

/-- FMT007: within a maximal run of imports uninterrupted by a blank line or comment, the module names
are not in ascending order. Reported at the first out-of-order import; report-only, because reordering
imports is observable to elaboration (`notes/01-semantics.md` §2) — the canonical rewrite is delivered
only through the opt-in organizer, never an unattended `fix`. -/
def orderFindings (header : HeaderModel) (normalized : String) : Array Finding := Id.run do
  let mut findings : Array Finding := #[]
  for i in [1:header.imports.size] do
    let prev := header.imports[i - 1]!
    let cur := header.imports[i]!
    if !groupBreakBetween normalized prev cur && cur.module.toString < prev.module.toString then
      findings := findings.push {
        code := "FMT007"
        severity := .warning
        message := s!"import {cur.module} is out of order (after {prev.module})"
        range := cur.range
        fix? := none
      }
  return findings

/-! ## FMT006 — redundant import (graph-validated, report-only, withholding)

The transitive closure is supplied by the caller (`Project`), which fetched it from the shared no-build
Lake graph. It maps each written import's module to the set of modules that import transitively pulls
in. A rule cannot fetch it (`Rules.lean:17-19`); this function is pure over the fetched facts. -/

/-- Whether `stmt` may be *reported* as a redundancy candidate at all. `import all`, `meta import`, and
a re-exported `public import` are **withheld**: reachability cannot reason about the private data, IR,
or downstream re-export they carry (`notes/01-semantics.md` §3). Only plain, non-re-exported imports
are eligible. -/
def redundancyEligible (header : HeaderModel) (stmt : ImportStmt) : Bool :=
  !stmt.importAll && !stmt.isMeta && !(header.hasModule && stmt.isExported)

/-- FMT006: a plain written import whose module is in the transitive closure of *another* written
import is a redundancy candidate. `closureOf name` returns the modules `name` transitively imports (or
`none` if the graph could not resolve it). Report-only always — reachability is necessary, not
sufficient, for safe removal. Duplicates are excluded (they are FMT005's). Returns the findings and the
withheld count (candidates skipped by `redundancyEligible`), which `RIR-FINAL` records. -/
def redundantFindings (header : HeaderModel) (closureOf : Lean.Name → Option (Array Lean.Name)) :
    Array Finding × Nat := Id.run do
  let mut findings : Array Finding := #[]
  let mut withheld := 0
  for h : i in [0:header.imports.size] do
    let stmt := header.imports[i]
    -- Skip a literal duplicate: FMT005 owns it, not redundancy.
    let isDup := (List.range i).any fun j =>
      match header.imports[j]? with
      | some earlier => sameImport earlier stmt
      | none => false
    if isDup then continue
    -- Is this module transitively pulled in by some *other* written import?
    let coveredBy := header.imports.findIdx? fun other =>
      other.module != stmt.module &&
        (match closureOf other.module with
         | some closure => closure.contains stmt.module
         | none => false)
    match coveredBy with
    | none => pure ()
    | some j =>
      if redundancyEligible header stmt then
        findings := findings.push {
          code := "FMT006"
          severity := .warning
          message := s!"import {stmt.module} is redundant: transitively available via \
            {header.imports[j]!.module}; verify before removing"
          range := stmt.range
          fix? := none
        }
      else
        withheld := withheld + 1
  return (findings, withheld)

/-! ## The organizer -/

/-- The canonical header text: the original header with duplicates removed and each blank-line/
comment-delimited group's imports sorted by module name, everything else — the `module` marker,
`prelude`, modifiers, comments, and group boundaries — preserved. This is the one operation the CLI and
LSP "organize imports" capability calls; it exposes no graph internals, only text in, text out.

Redundancy (FMT006) is **not** removed here — it is report-only, so the organizer surfaces candidates
through `redundantFindings` but never deletes them (`notes/01-semantics.md` §4). -/
def organize (header : HeaderModel) (normalized : String) : String := Id.run do
  if header.imports.isEmpty then return normalized
  -- Partition imports into groups separated by a blank line or comment.
  let mut groups : Array (Array Nat) := #[]
  let mut current : Array Nat := #[]
  for i in [0:header.imports.size] do
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
  for g in [0:groups.size] do
    let group := groups[g]!
    -- Keep, in written order, the first occurrence of each distinct statement.
    let mut kept : Array Nat := #[]
    for idx in group do
      let stmt := header.imports[idx]!
      let already := kept.any fun k => sameImport header.imports[k]! stmt
      unless already do kept := kept.push idx
    -- Sort kept lines by module name (stable on ties, which duplicates already removed).
    let sorted := kept.qsort fun a b =>
      header.imports[a]!.module.toString < header.imports[b]!.module.toString
    -- Emit each import's own line text (its statement bytes), newline-separated.
    let lines := sorted.map fun idx =>
      slice normalized header.imports[idx]!.range.start header.imports[idx]!.range.stop
    -- The gap before this group (from cursor to the group's first import start) is preserved verbatim.
    let groupStart := header.imports[group[0]!]!.range.start
    newImportRegion := newImportRegion ++
      slice normalized cursor groupStart ++
      String.intercalate "\n" lines.toList
    cursor := header.imports[group[group.size - 1]!]!.range.stop
  -- Reassemble: everything before the first import, the rebuilt region, everything after the last.
  return slice normalized 0 firstStart ++ newImportRegion ++
    slice normalized lastStop normalized.utf8ByteSize

end LeanFmt.Internal.Imports
