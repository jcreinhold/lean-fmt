module

public import Test.Fixture
public import Test.Harness
public import Test.Json
public import Test.Proc

/-!
# Exact-frontend analysis helpers for the `*-formatter` suites

The five formatter suites (block, collection, command, declaration, term) and the module suite all
drive the same shape: `lake setup-file` a fixture, run the binary's `__analyze-exact` at one or
more widths or modes, then assert against the envelope's canonical render or format draft. That
machinery lives here once.

Assertions here are whitespace-flexible patterns rather than golden strings: literal runs joined by
`\s*`-style gaps, explicit newlines, and `\b` word boundaries. `FlexTok` models exactly that
language and nothing more, so an assertion states a property of the output instead of copying it.
-/

open LeanFmt.Test

namespace LeanFmt.Test.Analyze

/-- One token in a whitespace-flexible pattern. -/
public inductive FlexTok where
  /-- Exact bytes. -/
  | lit (s : String)
  /-- `\s*`: a whitespace gap of any length, including zero. -/
  | anyWs
  /-- `\s+`: at least one whitespace character. -/
  | someWs
  /-- `\n` with flexible surroundings: a whitespace gap containing at least one newline. -/
  | newline
  /-- `\b`: exactly one side of this position is an identifier constituent. -/
  | wordBoundary
  deriving BEq

private def FlexTok.describe : FlexTok → String
  | .lit s => s!"lit({s})"
  | .anyWs => "\\s*"
  | .someWs => "\\s+"
  | .newline => "\\n"
  | .wordBoundary => "\\b"

/-- The small regular language above, as a pattern. -/
public abbrev FlexPattern :=
  List FlexTok

private def isIdChar (c : Char) : Bool :=
  c.isAlphanum || c == '_' || c == '\''

/-- Split a leading whitespace run off `chars`, reporting its length and whether it held a
newline. -/
private partial def splitWs : List Char → Nat → Bool → List Char × Nat × Bool
  | c :: rest, n, sawNewline =>
    if c.isWhitespace then splitWs rest (n + 1) (sawNewline || c == '\n')
    else (c :: rest, n, sawNewline)
  | [], n, sawNewline => ([], n, sawNewline)

/-- Deterministic match at one position: gaps skip exactly the whitespace run (literals never
start with whitespace, so there is nothing to backtrack into), and `prev?` is the character just
before the position, for `\b`. -/
private partial def matchAt (prev? : Option Char) (chars : List Char) : FlexPattern → Bool
  | [] => true
  | .lit s :: rest =>
    let literal := s.toList
    if chars.take literal.length == literal then
      matchAt literal.getLast? (chars.drop literal.length) rest
    else false
  | .anyWs :: rest =>
    let (chars', n, _) := splitWs chars 0 false
    -- Only `\b` reads `prev?`, and only to know whether it was an identifier constituent;
    -- whitespace is not one, so the exact skipped character is irrelevant.
    matchAt (if n > 0 then some ' ' else prev?) chars' rest
  | .someWs :: rest =>
    let (chars', n, _) := splitWs chars 0 false
    n > 0 && matchAt (some ' ') chars' rest
  | .newline :: rest =>
    let (chars', _, sawNewline) := splitWs chars 0 false
    sawNewline && matchAt (some '\n') chars' rest
  | .wordBoundary :: rest =>
    let left := prev?.map isIdChar |>.getD false
    let right := chars.head?.map isIdChar |>.getD false
    left != right && matchAt prev? chars rest

/-- The character index of the pattern's first occurrence, for ordering assertions. Positions are
character indices, not bytes — they are only ever compared against each other. -/
public partial def flexFind? (text : String) (pattern : FlexPattern) : Option Nat :=
  go none text.toList 0
where go (prev? : Option Char) (chars : List Char) (pos : Nat) : Option Nat :=
    if matchAt prev? chars pattern then some pos
    else
      match chars with
      | [] => none
      | c :: rest => go (some c) rest (pos + 1)

/-- Assert a whitespace-flexible pattern occurs, printing the text when it does not — the old
`assert re.search(...), text` with the pattern spelled out. -/
public def ensureFlex (label : String) (text : String) (pattern : FlexPattern) : IO Unit :=
  ensure ((flexFind? text pattern).isSome)
    s!"{label}: no match for {" ".intercalate (pattern.map FlexTok.describe)}\n{text}"

/-- Assert `text` ends with no trailing whitespace on any line — every width's render in the old
blocks asserted this. -/
public def ensureNoTrailingWhitespace (label : String) (text : String) : IO Unit := do
  for line in text.splitOn "\n" do
    ensure (!(line.endsWith " ") && !(line.endsWith "\t"))
        s!"{label}: trailing whitespace on line {repr line}"

/-- A Nat at the end of a JSON path, when it exists and is one. -/
public def natAt? (json : Lean.Json) (path : List JsonStep) : Option Nat :=
  (jsonAt? json path).bind fun value => (Lean.fromJson? value).toOption

/-- `lake setup-file` for the repo-relative `fixture`, written into `work`; returns the path. -/
public def setupFile (root work : System.FilePath) (fixture : String) : IO System.FilePath := do
  let setup ←
    expectExit 0 s!"lake setup-file {fixture}" "lake" #["setup-file", fixture] (cwd? := some root)
  let path := work / s!"setup-{fixture.replace "/" "-"}.json"
  writeFile path setup.stdout
  return path

/-- One `__analyze-exact` run, returning the parsed report. `mode` is the analyzer's mode argument
(`"4:80"`, `"draft:72"`, `"100"`, ...). The module suite's drafts go through `lake env`; the
formatter suites call the binary directly. -/
public def analyzeExact (root : System.FilePath) (application : String) (setup : System.FilePath)
    (source moduleName mode : String) (viaLakeEnv : Bool := false)
    (env : Array (String × Option String) := #[]) : IO Lean.Json := do
  let args := #["__analyze-exact", setup.toString, source, moduleName, mode]
  let label := s!"__analyze-exact {source} at {mode}"
  let result ←
    if viaLakeEnv then
      expectExit 0 label "lake" (#["env", application] ++ args) (cwd? := some root) (env := env)
    else
      expectExit 0 label application args (cwd? := some root) (env := env)
  parseJson result.stdout label

/-- The canonical render of a successful report: validation absent-or-null (the binary omits the
key on success), canonical present, idempotence exactly one pass. Returns the canonical object and its text; metrics stay fixture-specific, so
each suite asserts its own against the returned object. -/
public def canonical (report : Lean.Json) (label : String) : IO (Lean.Json × String) := do
  ensure (jsonAt? report [.field "validationFailure"] |>.all (· == Lean.Json.null))
      s!"{label}: validation failed"
  let some canonical :=
    jsonAt? report [.field "canonical"] | throw <| IO.userError s!"{label}: no canonical render"
  ensureJsonAt canonical [.field "validation", .field "idempotencePasses"] (Lean.toJson (1 : Nat))
      label
  let some text :=
    (canonical.getObjValAs? String
        "text").toOption | throw <| IO.userError s!"{label}: canonical text missing"
  return (canonical, text)

/-- The envelope's ownership summary, validated: what the retired `comment-summary` subcommand
checked, without decoding the envelope type — `valid`, and the counts partition. Returns the raw
summary JSON; callers read counts and the payload digest off it. -/
public def commentSummary (report : Lean.Json) (label : String) : IO Lean.Json := do
  let some summary :=
    jsonAt? report
      [.field
          "commentSummary"] | throw <| IO.userError s!"{label}: exact frontend captured no comment ownership summary"
  ensureJsonAt summary [.field "valid"] (Lean.toJson true) label
  let comments := (natAt? summary [.field "comments"]).getD 0
  let parts :=
    (["leading", "trailing", "dangling"].map fun key => (natAt? summary [.field key]).getD 0).foldl
      (· + ·) 0
  ensure (comments == parts) s!"{label}: ownership counts do not partition"
  return summary

/-- The format draft of a successful report: formatFailure absent-or-null, draft present. -/
public def formatDraft (report : Lean.Json) (label : String) : IO Lean.Json := do
  ensure (jsonAt? report [.field "formatFailure"] |>.all (· == Lean.Json.null))
      s!"{label}: format failed"
  let some draft :=
    jsonAt? report [.field "formatDraft"] | throw <| IO.userError s!"{label}: no format draft"
  return draft

/-- The resolved repo root, the built binary's path, and a scratch work dir — the three things
every analysis suite's main needs, bundled so the suites read as assertion lists. -/
public def withRun (suite : String)
    (k : (root work : System.FilePath) → (application : String) → IO UInt32) : IO UInt32 := do
  let root ← repoRoot
  withScratchDir suite fun work =>
      k root work (root / ".lake" / "build" / "bin" / "lean-fmt").toString

end LeanFmt.Test.Analyze
