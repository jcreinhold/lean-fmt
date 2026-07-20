module

import all LeanFmt.Discovery

open System

namespace LeanFmt.Internal.GitSelection

/-! # Version-control changed-file selection

The private adapter `ruff-16` RWI-IMPL owes
(`docs/projects/ruff-16-watch-incremental/notes/01-watch-generations.md` §9). It answers exactly one
question — *which paths did version control change* — and produces a path list plus the provenance a
partial run must report. It does not decide what a path means: `.lean`-ness, `.lake` exclusion,
configured `include`/`exclude`, ordering, and snapshotting all stay in `LeanFmt.Project` and
`LeanFmt.Discovery`, reached through the ordinary `execute` (§9.5 steps 3–4).

Two measured facts shape everything here, both recorded in `evidence/01-watch-baseline.md`:

* Only `-z` yields byte-exact paths. Default `git diff` C-quotes non-ASCII into octal escapes, and
  `core.quotePath=false` fixes that case while **still** quoting an embedded double quote. A
  line-splitting adapter is therefore wrong on ordinary Unicode filenames (§9.2).
* A missing binary is an exit code, not an exception. `IO.Process.output` returns 255 rather than
  throwing, so the natural `try`/`catch` spelling of "Git absence is a request error" never fires
  (§9.7).
-/

/-- Which comparison the caller asked for (§9.1).

Three questions, not three spellings of one. `worktree` asks what differs from `HEAD` right now,
`base` asks what this branch changed since it diverged, and `staged` asks what is about to be
committed. -/
inductive Comparison where
  /-- `--changed`: worktree against `HEAD`, plus untracked files. -/
  | worktree
  /-- `--changed BASE`: three-dot merge-base against `BASE`. -/
  | base (revision : String)
  /-- `--staged`: the index against `HEAD`. -/
  | staged
  deriving BEq

def Comparison.describe : Comparison → String
  | .worktree => "worktree vs HEAD"
  | .base revision => s!"{revision}...HEAD (merge base)"
  | .staged => "index vs HEAD"

/-- Why a path git named was not selected (§9.6).

Silent dropping is what makes a partial run look complete, so every reason a caller would want to
know is carried out of the adapter rather than discarded inside it. Paths dropped by the *ordinary*
selection gates — not `.lean`, inside `.lake`, configured `exclude` — are not listed here: those are
`Discovery`'s answer to give, and duplicating them would be a second matcher. -/
inductive Dropped where
  /-- The file no longer exists: a delete, or a rename's old path. -/
  | deleted (path : String)
  /-- A conflicted file. Formatting one would be answering the wrong question. -/
  | unmerged (path : String)
  /-- Git named it, but it lies outside `--root`. A repository can hold several projects. -/
  | outsideRoot (path : String)
  deriving BEq

def Dropped.describe : Dropped → String
  | .deleted path => s!"{path}: deleted"
  | .unmerged path => s!"{path}: unmerged"
  | .outsideRoot path => s!"{path}: outside the selected root"

/-- What the adapter observed: paths to select, and everything a partial report must disclose. -/
structure Selection where
  /-- Absolute paths, existing, inside the root. Ordering is left to the ordinary run. -/
  paths : Array FilePath
  /-- The comparison performed, for the report's provenance line. -/
  comparison : Comparison
  /-- The resolved commit the comparison ran against, when there is one. -/
  resolvedBase? : Option String
  /-- Paths git named that this adapter withheld, with the reason (§9.6). -/
  dropped : Array Dropped

/-! ## Running git

Every invocation goes through `git`, whose absence and whose non-repository state are request errors
(§9.7). -/

private structure GitOutput where
  exitCode : UInt32
  stdout : String
  stderr : String

/-- `exitCode = 255` is what `IO.Process.output` returns when the binary does not exist
(`evidence` §4) — it does not throw, so this is the only place absence can be detected. -/
private def missingBinaryCode : UInt32 := 255

private def runGit (cwd : FilePath) (args : Array String) : IO GitOutput := do
  let output ← IO.Process.output { cmd := "git", args, cwd := some cwd }
  return { exitCode := output.exitCode, stdout := output.stdout, stderr := output.stderr }

/-- The first line of git's stderr, which is the whole diagnostic for the commands used here.

`git diff` outside a repository exits 129 after printing ~90 lines of option usage, which is why §9.7
probes with `rev-parse` instead; this keeps a surprising failure from pasting a manual into the
user's terminal. -/
private def firstLine (text : String) : String :=
  match (text.trimAscii.toString.splitOn "\n").head? with
  | some line => line.trimAscii.toString
  | none => "git failed"

private def absent : String :=
  "git is required for changed-file selection but was not found on PATH"

/-- Establish that `root` is inside a work tree and return its toplevel.

Probes with `rev-parse --show-toplevel`, never with `git diff`: outside a repository `rev-parse` exits
128 with one clean line, where `git diff` exits 129 after dumping its entire option usage
(`evidence` §5). -/
private def repositoryToplevel (root : FilePath) : IO (Except String FilePath) := do
  let output ← runGit root #["rev-parse", "--show-toplevel"]
  if output.exitCode == missingBinaryCode then
    return .error absent
  if output.exitCode != 0 then
    return .error s!"changed-file selection requires a git repository: {firstLine output.stderr}"
  let toplevel := output.stdout.trimAscii.toString
  if toplevel.isEmpty then
    return .error "git reported no repository toplevel"
  return .ok (FilePath.mk toplevel)

/-- Resolve a caller-supplied revision, naming what they typed when it does not exist (§9.7). -/
private def resolveRevision (root : FilePath) (revision : String) :
    IO (Except String String) := do
  let output ← runGit root #["rev-parse", "--verify", "--quiet", revision ++ "^{commit}"]
  if output.exitCode == missingBinaryCode then
    return .error absent
  if output.exitCode != 0 then
    return .error s!"unknown revision: {revision}"
  return .ok (output.stdout.trimAscii.toString)

/-! ## Parsing the `-z` stream

NUL-terminated fields with a **status-dependent field count**: a rename is three fields (`R###`, old
path, new path), every other status is two (§9.2). A parser that assumes pairs desynchronizes on the
first rename and mis-assigns every path after it, so the arity is read from the status letter. -/

/-- Split a NUL-terminated stream into its fields, discarding the empty tail after the final NUL.

`String.splitOn` is used rather than a line reader precisely because the payload may contain newlines:
a filename is allowed to, and `-z` exists so that it can. -/
private def nulFields (stream : String) : Array String :=
  let parts := stream.splitOn "\x00"
  (parts.filter (!·.isEmpty)).toArray

/-- One change record: a status field and the path that matters after it. -/
private structure Record where
  /-- The raw status field, e.g. `M`, `D`, `U`, or a scored `R100`. -/
  status : String
  /-- For a rename this is the **new** path; the old one is gone and is reported as deleted. -/
  path : String
  /-- A rename's old path, so it can be disclosed rather than silently dropped. -/
  previous? : Option String := none

/-- `R` (rename) and `C` (copy) carry a source *and* a destination; every other status carries one
path. Reading the arity from the status letter is what keeps the parser in phase — assuming pairs
desynchronizes on the first rename and mis-assigns every path after it (§9.2). -/
private def hasTwoPaths (status : String) : Bool :=
  status.startsWith "R" || status.startsWith "C"

private def parseNameStatus (stream : String) : Array Record := Id.run do
  let fields := nulFields stream
  let mut records : Array Record := #[]
  let mut index := 0
  while index < fields.size do
    let status := fields[index]!
    if hasTwoPaths status then
      if index + 2 < fields.size then
        records := records.push
          { status, path := fields[index + 2]!, previous? := some fields[index + 1]! }
      index := index + 3
    else
      if index + 1 < fields.size then
        records := records.push { status, path := fields[index + 1]! }
      index := index + 2
  return records

/-! ## Selection -/

private def diffArguments : Comparison → Array String
  | .worktree => #["diff", "--name-status", "-z", "--find-renames", "HEAD"]
  -- Three-dot, measured: two-dot reported ten paths on a diverged fixture — including a deletion the
  -- branch never performed — where three-dot reported the two files it actually touched
  -- (`evidence` §8). "What did my branch change" is the merge-base question.
  | .base revision =>
    #["diff", "--name-status", "-z", "--find-renames", revision ++ "...HEAD"]
  | .staged => #["diff", "--cached", "--name-status", "-z", "--find-renames", "HEAD"]

/-- `--find-renames` is passed explicitly rather than relying on the `diff.renames` default, which a
user's configuration can turn off (`results/01-contract.md`, remaining uncertainty). -/
private def untrackedArguments : Array String :=
  #["ls-files", "--others", "--exclude-standard", "-z"]

/-- Whether this comparison unions in untracked files.

`git diff` **never** reports them (`evidence` §7): a newly created file appears only in
`ls-files --others`, so a selection built from `diff` alone silently skips every brand-new file —
which is exactly when a formatter is most wanted. A merge-base comparison is a question about
committed history and does not union them (§9.4). -/
private def includesUntracked : Comparison → Bool
  | .worktree => true
  | .base _ => false
  | .staged => false

/-- Resolve a repository-relative path against the toplevel and confine it to `root`.

Returns `none` for a path outside the root: a repository can hold several projects, and formatting a
sibling because it shares a repository would violate the root contract (§9.5 step 2). -/
private def confine (toplevel root : FilePath) (relative : String) : IO (Option FilePath) := do
  let candidate := toplevel / FilePath.mk relative
  -- Compare resolved paths so that a symlinked or `..`-bearing root still confines correctly. A path
  -- that does not exist cannot be selected anyway, so a failed resolution is simply not selected.
  try
    let resolved ← IO.FS.realPath candidate
    let rootResolved ← IO.FS.realPath root
    let resolvedText := resolved.toString
    let rootText := rootResolved.toString
    if resolvedText == rootText || resolvedText.startsWith (rootText ++ "/") then
      return some resolved
    return none
  catch _ =>
    return none

/-- Select the paths version control reports as changed (§9).

The result is a path list and its provenance. Everything about what a path *means* — whether it is a
Lean source, whether configuration excludes it, what order it runs in — is left to the ordinary
selection this feeds. -/
def select (root : FilePath) (comparison : Comparison) : IO (Except String Selection) := do
  let toplevel ← match ← repositoryToplevel root with
    | .error message => return .error message
    | .ok toplevel => pure toplevel

  let resolvedBase? ← match comparison with
    | .base revision =>
      match ← resolveRevision root revision with
      | .error message => return .error message
      | .ok resolved => pure (some resolved)
    | _ => pure none

  let diff ← runGit root (diffArguments comparison)
  if diff.exitCode == missingBinaryCode then
    return .error absent
  if diff.exitCode != 0 then
    return .error s!"git could not compare {comparison.describe}: {firstLine diff.stderr}"

  let mut candidates : Array String := #[]
  let mut dropped : Array Dropped := #[]

  for record in parseNameStatus diff.stdout do
    -- A rename's old path is gone whether or not the new one is selected, and disclosing it is what
    -- keeps a partial run honest.
    if let some previous := record.previous? then
      dropped := dropped.push (.deleted previous)
    -- `D`: nothing to format, and naming it would be a path error about a file the caller never
    -- named. `U`: a conflicted file is not something to format.
    if record.status.startsWith "D" then
      dropped := dropped.push (.deleted record.path)
    else if record.status.startsWith "U" then
      dropped := dropped.push (.unmerged record.path)
    else
      candidates := candidates.push record.path

  if includesUntracked comparison then
    let untracked ← runGit root untrackedArguments
    if untracked.exitCode == missingBinaryCode then
      return .error absent
    if untracked.exitCode != 0 then
      return .error s!"git could not list untracked files: {firstLine untracked.stderr}"
    for path in nulFields untracked.stdout do
      candidates := candidates.push path

  let mut paths : Array FilePath := #[]
  let mut seen : Array String := #[]
  for relative in candidates do
    match ← confine toplevel root relative with
    | none =>
      -- Distinguish "git named a path outside the root" from "the path is gone": the first is a
      -- boundary the caller should know about, the second is already recorded above.
      let candidate := toplevel / FilePath.mk relative
      if ← candidate.pathExists then
        dropped := dropped.push (.outsideRoot relative)
    | some resolved =>
      let text := resolved.toString
      unless seen.contains text do
        seen := seen.push text
        paths := paths.push resolved

  return .ok { paths, comparison, resolvedBase?, dropped }

end LeanFmt.Internal.GitSelection
