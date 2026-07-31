/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.LosslessSource
import all LeanFmt.Rules

/-! # Source-level suppression directives

The model in one line: a directive is read **only** from a `Comment` (a `lineComment`/`blockComment`
trivia), never by substring search, so strings, syntax quotations, and doc comments are excluded by
construction. A directive suppresses canonical findings whose anchor falls in its byte scope, and an
unused directive is itself a finding (`FMT900`) with a safe removal fix. Suppression is a **projection
over findings**, applied after canonical results and after config selection; like selection it never
enters the result-cache identity.

Placement in the pipeline: `runRules` (engine) → `RulePlan.findings` (config layer) → `Suppression`
(this module, source layer) → report. The report gains the surviving findings, a suppressed count,
and the `FMT900`/`FMT901` self-diagnostics. -/

namespace LeanFmt.Internal

/-- Which of the three forms a directive is. The scope each denotes is computed in `directiveScope`;
the verb only names the form. -/
inductive DirectiveScope where
  | line
  | nextItem
  | file
  deriving Inhabited, BEq, DecidableEq, Repr

private def DirectiveScope.toIndex : DirectiveScope → Nat
  | .line => 0
  | .nextItem => 1
  | .file => 2

private def DirectiveScope.ofIndex? : Nat → Option DirectiveScope
  | 0 => some .line
  | 1 => some .nextItem
  | 2 => some .file
  | _ => none

instance : Lean.ToJson DirectiveScope :=
  ⟨fun s => Lean.toJson s.toIndex⟩

instance : Lean.FromJson DirectiveScope :=
  ⟨fun j => do
    let some s := DirectiveScope.ofIndex? (← Lean.fromJson? j) | .error "unknown directive scope"
    return s⟩

/-- A parsed, well-formed directive, resolved to a byte scope in the normalized source.

`codes?` is `none` for a blanket directive; `some codes` names specific rule codes (`codes` is
nonempty — an empty `[]` is malformed and never reaches here). `scopeRange` is the byte range whose
findings this suppresses, and `commentRange` is the directive comment's own range, needed by the
`FMT900` removal fix. Both ranges derive from the comment's position every run (§3 of the spec), so
they are stable under formatting, not stored offsets a reflow could invalidate. -/
structure Directive where
  scope : DirectiveScope
  codes? : Option (Array String)
  scopeRange : SourceRange
  commentRange : SourceRange
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The facts a run's suppression layer needs, computed where the projection is available (analysis
time) and carried to the report layer. Both fields are pure functions of the source, so caching them
alongside the findings changes no identity — a directive is as much a source fact as a finding is. -/
structure SuppressionFacts where
  directives : Array Directive := #[]
  /-- `FMT901` findings for comments that open with the sigil but break the grammar. Computed here
  because malformedness depends on the comment alone, not on any other finding. -/
  malformed : Array Finding := #[]
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

namespace Suppression

/-- The sigil every directive comment opens with. Chosen over ruff's `noqa` because Lean has no `#`
line comment. -/
def sigil : String :=
  "lean-fmt:"

/-- A cheap whole-source superset test for "could this file carry a directive?". A substring scan of
the *raw* source, deliberately over-broad: it fires on the sigil anywhere — inside a string, a doc
comment, even a rule message — none of which `collect` treats as a directive. That asymmetry is the
point. `collect` is exact but needs the syntax projection; this gate needs none, so
`availableAnalysis` uses it to decide when a file that would otherwise take the source-only shortcut
must instead demand the projection. A false positive costs one file its shortcut; a false negative
would silently drop a real directive, so the test must never miss — and a substring scan cannot. -/
def mayContainDirective (source : String) : Bool :=
  (source.splitOn sigil).length > 1

private def isUpper (c : Char) : Bool :=
  'A' ≤ c && c ≤ 'Z'

private def isAlnum (c : Char) : Bool :=
  c.isAlphanum

/-- Trim leading/trailing ASCII whitespace, returning an owned `String`. -/
private def trim (s : String) : String :=
  s.trimAscii.copy

/-- A rule-code shape: an uppercase letter followed by letters/digits (`FMT001`). This is a *shape*
check; whether the code names a registered rule is a separate question the unused rule answers. -/
private def isCodeShape (s : String) : Bool :=
  match s.toList with
  | [] => false
  | c :: rest => isUpper c && rest.all isAlnum

/-- Strip a comment's delimiters, leaving its inner text. A `lineComment` is `-- …` to end of line; a
`blockComment` is `/- … -/`. Doc comments never reach here — they are not trivia. -/
private def commentBody (kind : TriviaKind) (text : String) : String :=
  match kind with
  | .lineComment => String.ofList (text.toList.drop 2)
  | .blockComment =>
    -- drop the leading "/-" and the trailing "-/"; a block comment is at least "/--/" so this is safe
    String.ofList (text.toList.drop 2 |>.dropLast |>.dropLast)
  | .whitespace => text

/-- Parse the grammar `verb (ws? "[" codes "]")?` that follows the sigil.

Returns `.error reason` on any grammar violation (malformed) and `.ok (scope, codes?)` on success.
`codes?` is `none` for a blanket verb and `some nonEmpty` otherwise. -/
private def parseBody (afterSigil : String) :
    Except String (DirectiveScope × Option (Array String)) := do
  let rest := trim afterSigil
  -- Split verb from an optional bracketed selector list. More than one '[' is malformed.
  let (verbStr, bracket?) ←
    match rest.splitOn "[" with
    | [only] =>
      pure (trim only, none)
    | [verb, sel] =>
      pure (trim verb, some sel)
    | _ =>
      throw "more than one '[' in suppression directive"
  let scope ←
    match verbStr with
    | "ignore" =>
      pure DirectiveScope.line
    | "ignore-next" =>
      pure DirectiveScope.nextItem
    | "ignore-file" =>
      pure DirectiveScope.file
    | other =>
      throw s!"unknown suppression verb '{other}'"
  match bracket? with
  | none =>
    return (scope, none)
  | some sel =>
    -- The bracketed part must close with exactly one ']' and carry nothing after it.
    let (codesStr, tail) ←
      match sel.splitOn "]" with
      | [codes, tail] =>
        pure (codes, tail)
      | [_] =>
        throw "unclosed '[' in suppression directive"
      | _ =>
        throw "more than one ']' in suppression directive"
    unless (trim tail).isEmpty do
      throw "trailing text after suppression directive"
    let codes := (codesStr.splitOn ",").map trim
    if codes.any (·.isEmpty) then
      throw "empty rule code in suppression directive"
    unless codes.all isCodeShape do
      throw "malformed rule code in suppression directive"
    return (scope, some codes.toArray)

/-- Byte offset just past the previous newline before `pos` (the start of `pos`'s line). -/
private def lineStart (bytes : ByteArray) (pos : Nat) : Nat :=
  Id.run do
    let mut i := pos
    while i > 0 && bytes[i - 1]! != 0x0a do
      i := i - 1
    return i

/-- Byte offset of the next newline at or after `pos`, or `bytes.size` if none (the line's stop). -/
private def lineStop (bytes : ByteArray) (pos : Nat) : Nat :=
  Id.run do
    let mut i := pos
    while i < bytes.size && bytes[i]! != 0x0a do
      i := i + 1
    return i

/-- The command roots of a projection, in source order: nodes with no parent. Their ranges partition
the command stream, so consecutive roots bound one item and its trailing trivia. -/
private def commandRoots (src : LosslessSource) : Array Node :=
  src.nodes.filter (·.parent.isNone) |>.qsort (fun a b => a.range.start < b.range.start)

/-- Resolve a directive's byte scope from the comment position and the projection.

- `file` — `[0, normalizedBytes]`: the whole module, inclusive of the end-of-file anchor so a file
  directive can suppress a zero-width end-of-file finding (an empty `[eof, eof]` range).
- `line` — the physical source line the comment sits on. A trailing directive covers the code it
  trails; a leading one covers only its own line.
- `nextItem` — the next command and its trailing trivia: from the following command-root's start to
  the command-root after that (or `terminalStop`). Extending to the next root captures trailing
  whitespace, which lives past a command's own node range. -/
private def directiveScope (src : LosslessSource) (bytes : ByteArray) (scope : DirectiveScope)
    (comment : SourceRange) : SourceRange :=
  match scope with
  | .file => ⟨0, bytes.size⟩
  | .line => ⟨lineStart bytes comment.start, lineStop bytes comment.start⟩
  | .nextItem =>
    let roots := commandRoots src
    let after := roots.filter (·.range.start ≥ comment.stop)
    match after[0]? with
    | none => ⟨comment.stop, comment.stop⟩
    | some cmd =>
      let stop := (after[1]?.map (·.range.start)).getD src.terminalStop
      ⟨cmd.range.start, max stop cmd.range.stop⟩

/-- Whether a finding's anchor lies in a scope. Anchoring on `range.start` (not full containment)
keeps line rules robust against findings whose range ends on a line boundary or is empty: a finding
whose range ends at the trailing newline still anchors on its line, and a zero-width `[eof, eof]`
finding anchors at end of file. The empty-finding clause admits a zero-width finding sitting exactly
on the scope's upper bound, which is how a `file`- or last-line-`line`-scoped directive catches an
end-of-file finding. (The retired line-boundary and final-newline rules were the original examples.) -/
def inScope (scope : SourceRange) (finding : Finding) : Bool :=
  scope.start ≤ finding.range.start &&
    (finding.range.start < scope.stop ||
      (finding.range.start == scope.stop && finding.range.start == finding.range.stop))

private def malformedFinding (comment : SourceRange) (reason : String) : Finding :=
  { code := "FMT901"
    severity := .warning
    message := s!"malformed suppression directive: {reason}"
    range := comment
    -- Removing a broken directive may discard the author's intent, so the fix is shown, never applied.
    fix? :=
      some { applicability := .displayOnly, edits := #[{ range := comment, replacement := "" }] } }

/-- Comments in the module header `[0, headerStop)`, which the compiler artifact deliberately omits.

The header is not in the artifact's trivia projection, so a directive placed at the top of a file —
the natural home for `ignore-file` — would otherwise be silently dropped: no suppression and, worse,
no diagnostic. This recovers those comments so they parse like any other.

A dedicated scanner is safe here because the header grammar is so small. In the module system, the
header holds only the `module` marker, `import` statements, and interspersed whitespace and comments:
`headerStop` is the *first command's* leading start (`LosslessSource.lean` `firstLeadingStart?`), and
module/doc docstrings parse as commands, so they sit past `headerStop`, never inside this region.
That leaves no string literal and no docstring here to misread — the two things a substring scan
cannot survive. So the scan skips non-comment bytes one at a time (handling `module`, `import`, and
identifiers uniformly) and records line and block comments by range. A stray block comment is skipped
whole with nested counting, so a directive-looking line *inside* one is never torn out; and were a
docstring ever to appear, its body begins with a bang or dash once the block delimiters are stripped,
so `commentBody` yields no sigil match. -/
private def headerComments (bytes : ByteArray) (headerStop : Nat) :
    Array (TriviaKind × SourceRange) :=
  Id.run do
    let mut out := #[]
    let stop := min headerStop bytes.size
    let mut i := 0
    while i < stop do
      let b := bytes[i]!
      if b == 0x2d && i + 1 < stop && bytes[i + 1]! == 0x2d then
        -- `--` line comment: runs to, but excludes, the newline.
        let mut j := i + 2
        while j < stop && bytes[j]! != 0x0a do
          j := j + 1
        out := out.push (.lineComment, ⟨i, j⟩)
        i := j
      else if b == 0x2f && i + 1 < stop && bytes[i + 1]! == 0x2d then
        -- `/- … -/` block comment, nested; also absorbs any `/-!`/`/--` whole.
        let mut j := i + 2
        let mut nesting := 1
        while j + 1 < stop && nesting > 0 do
          if bytes[j]! == 0x2d && bytes[j + 1]! == 0x2f then
            nesting := nesting - 1
            j := j + 2
          else if bytes[j]! == 0x2f && bytes[j + 1]! == 0x2d then
            nesting := nesting + 1
            j := j + 2
          else
            j := j + 1
        out := out.push (.blockComment, ⟨i, j⟩)
        i := j
      else
        -- Whitespace or a code byte (`module`, `import`, an identifier): skip one and re-scan.
        i := i + 1
    return out

/-- Directive-eligible comments in the compiler artifact's command-body trivia. This projection scan
belongs to suppression, which must run on artifact-only rule paths; formatter comment ownership uses
actual `Syntax` and is intentionally not serialized into the artifact. -/
private def bodyComments (src : LosslessSource) : Array (TriviaKind × SourceRange) :=
  Id.run do
    let scan (runs : Array Trivia) (start : Nat) : Array (TriviaKind × SourceRange) × Nat :=
      Id.run do
        let mut comments := #[]
        let mut cursor := start
        for run in runs do
          if run.kind == .lineComment || run.kind == .blockComment then
            comments := comments.push (run.kind, ⟨cursor, run.stop⟩)
          cursor := run.stop
        return (comments, cursor)
    let mut result := #[]
    let mut cursor := src.headerStop
    for token in src.tokens do
      let (leading, _) := scan token.leading cursor
      result := result ++ leading
      let (trailing, trailingStop) := scan token.trailing token.stop
      result := result ++ trailing
      cursor := trailingStop
    return result

/-- Parse every directive comment in a module into `SuppressionFacts`.

Directives are read from recorded artifact trivia for the command body plus `headerComments` for the
module header the artifact omits; formatter ownership is neither required nor serialized on this
rule-only path. A comment whose body does not open with the sigil is ordinary prose and produces
nothing; one that opens with the sigil but breaks the grammar becomes an `FMT901` finding and
suppresses nothing. -/
def collect (src : LosslessSource) (normalized : String) : SuppressionFacts :=
  Id.run do
    let bytes := normalized.toUTF8
    let mut directives := #[]
    let mut malformed := #[]
    -- Header first keeps global source order, so `FMT900`/`FMT901` report top-to-bottom.
    let comments := headerComments bytes src.headerStop ++ bodyComments src
    for (kind, range) in comments do
      let text := (String.fromUTF8? (bytes.extract range.start range.stop)).getD ""
      let body := trim (commentBody kind text)
      if body.startsWith sigil then
        let afterSigil := String.ofList (body.toList.drop sigil.length)
        if trim afterSigil == "format-ignore-next" then
          let scopeRange := directiveScope src bytes .nextItem range
          if range.stop <= src.headerStop then
            malformed :=
              malformed.push
                (malformedFinding range
                  "formatter suppression cannot target the module/import header")
          else if scopeRange.start == scopeRange.stop then
            malformed :=
              malformed.push
                (malformedFinding range "formatter suppression has no following ordinary unit")
        else
          match parseBody afterSigil with
          | .error reason =>
            malformed := malformed.push (malformedFinding range reason)
          | .ok (scope, codes?) =>
            directives :=
              directives.push
                { scope, codes?
                  scopeRange := directiveScope src bytes scope range
                  commentRange := range }
    return { directives, malformed }

/-- Does this directive suppress `finding`? The code must be in scope and either blanket or named. -/
private def suppresses (directive : Directive) (finding : Finding) : Bool :=
  inScope directive.scopeRange finding &&
    match directive.codes? with
    | none => true
    | some codes => codes.contains finding.code

/-- The byte range to delete when removing a fully-unused directive comment.

If the comment is alone on its line (only whitespace precedes it) the whole line goes, newline
included; otherwise only the comment and the horizontal whitespace immediately before it go, leaving
the code. Both are meaning-preserving at the byte level — the lexer cannot see a comment — so the fix
is genuinely safe. -/
private def removalRange (bytes : ByteArray) (comment : SourceRange) : SourceRange :=
  let ls := lineStart bytes comment.start
  let precededOnlyByWhitespace :=
    Id.run do
      let mut i := ls
      while i < comment.start do
        let b := bytes[i]!
        unless b == 0x20 || b == 0x09 do
          return false
        i := i + 1
      return true
  if precededOnlyByWhitespace then
    let stop := lineStop bytes comment.start
    ⟨ls, if stop < bytes.size then stop + 1 else stop⟩
  else
    let start :=
      Id.run do
        let mut start := comment.start
        while start > ls && (bytes[start - 1]! == 0x20 || bytes[start - 1]! == 0x09) do
          start := start - 1
        return start
    ⟨start, comment.stop⟩

/-- Reconstruct a directive comment keeping only `codes`, in canonical `lean-fmt:` spelling. Used by the
list-trim fix when some but not all of a list's codes are unused. -/
private def rewriteDirective (scope : DirectiveScope) (codes : Array String) : String :=
  let verb :=
    match scope with
    | .line => "ignore"
    | .nextItem => "ignore-next"
    | .file => "ignore-file"
  s!"-- lean-fmt: {verb}[{String.intercalate ", " codes.toList}]"

private def unusedFinding (range : SourceRange) (message : String) (fix : Fix) : Finding :=
  { code := "FMT900", severity := .warning, message, range, fix? := some fix }

/-- The result of projecting directives over the config-selected findings. -/
structure Outcome where
  /-- Findings that survive suppression, in the input order. -/
  kept : Array Finding
  /-- How many findings the directives removed. -/
  suppressed : Nat
  /-- `FMT900` findings for directives (or codes) that suppressed nothing. -/
  unused : Array Finding

/-- Project directives over `findings` (already config-selected for the path).

A finding is kept unless some directive suppresses it. A directive — or one code of a list — is
*unused* when it suppressed nothing among these findings, which is why unused is computed against the
config-selected set (§8): a directive naming a config-disabled or unknown code can never fire and is
reported. The `bytes` are the normalized source, needed to compute removal ranges. -/
def apply (facts : SuppressionFacts) (bytes : ByteArray) (findings : Array Finding) : Outcome :=
  Id.run do
    let mut kept := #[]
    for finding in findings do
      if facts.directives.any (suppresses · finding) then
        pure ()
      else
        kept := kept.push finding
    let suppressed := findings.size - kept.size
    let mut unused := #[]
    for directive in facts.directives do
      match directive.codes? with
      | none =>
        -- blanket: unused iff it suppressed nothing in scope
        unless findings.any (fun f => inScope directive.scopeRange f) do
          unused :=
            unused.push
              (unusedFinding directive.commentRange
                "unused blanket suppression directive: no finding in its scope"
                { applicability := .safe,
                  edits :=
                    #[{ range := removalRange bytes directive.commentRange, replacement := "" }] })
      | some codes =>
        let used :=
          codes.filter fun code =>
            findings.any fun f => f.code == code && inScope directive.scopeRange f
        -- A reserved/retired code is **inert**: it suppresses
        -- nothing but is never flagged unused, so it stays out of the dead set that raises `FMT900`.
        -- A retired-only directive therefore raises nothing (`dead` is empty); a mixed directive keeps
        -- normal per-code analysis for its live codes, and a trim preserves the inert retired codes in
        -- place.
        let dead := codes.filter fun code => !used.contains code && !isReservedCode code
        let keep := codes.filter fun code => used.contains code || isReservedCode code
        if used.isEmpty then
          -- every live code dead: remove the whole directive (a retired-only directive has empty `dead`)
          unless dead.isEmpty do
            unused :=
              unused.push
                (unusedFinding directive.commentRange
                  s!"unused suppression directive: {String.intercalate ", " dead.toList} suppress nothing here"
                  { applicability := .safe,
                    edits :=
                      #[{ range := removalRange bytes directive.commentRange,
                          replacement := "" }] })
        else if !dead.isEmpty then
          -- some codes live: trim the list to the used (and inert retired) codes
          unused :=
            unused.push
              (unusedFinding directive.commentRange
                s!"unused suppression codes: {String.intercalate ", " dead.toList}"
                { applicability := .safe,
                  edits :=
                    #[{ range := directive.commentRange,
                        replacement := rewriteDirective directive.scope keep }] })
    return { kept, suppressed, unused }

end Suppression

end LeanFmt.Internal
