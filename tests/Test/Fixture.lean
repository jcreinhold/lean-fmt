module

import Test.Proc

/-!
# Filesystem fixtures

Two kinds of scratch space, and the rule that decides between them:

- `withTempDir` is the default. It lives wherever the OS puts temp dirs, and the suite's world —
  configs, fixture projects, whole consuming workspaces — is copied into it. Nothing it contains
  can dirty the working tree, which is the property that lets `parallel`-lane suites overlap.
- `withScratchDir` is for files that must sit *inside this package's workspace*: a scratch module
  has to be under the lake root for `lake setup-file` and the exact frontend to elaborate it the
  way a project file is elaborated (the shell suites wrote `.probe-*.lean` next to the fixtures for
  this reason). It lives under `tests/.scratch/` — git-ignored — and is removed by the same
  `finally` discipline either way.

`copyTree` skips build state by default: copying a fixture project's `.lake` would transplant
absolute paths and stale traces into the temp copy, and the suite's first act is a fresh build
anyway.
-/

namespace LeanFmt.Test

/-- Create a temp directory, run `f` in it, remove it afterwards — including on failure, which is
the discipline the shell suites got from `trap` and a port must not lose. -/
public def withTempDir (f : System.FilePath → IO α) : IO α := do
  let directory ← IO.FS.createTempDir
  try
    f directory
  finally
    IO.FS.removeDirAll directory

/-- The repository root, resolved through git so suites work from any working directory the runner
invokes them in. -/
public def repoRoot : IO System.FilePath := do
  let result ← runProc "git" #["rev-parse", "--show-toplevel"]
  ensure (result.exitCode == 0) s!"git rev-parse failed:\n{result.stderr}"
  return ⟨result.stdout.trimAscii.toString⟩

/-- Create a scratch directory named after `suite` under the git-ignored `tests/.scratch/`, run
`f` in it, remove it afterwards. -/
public def withScratchDir (suite : String) (f : System.FilePath → IO α) : IO α := do
  let root ← repoRoot
  let directory := root / "tests" / ".scratch" / s!"{suite}-{← IO.rand 0 999999}"
  IO.FS.createDirAll directory
  try
    f directory
  finally
    IO.FS.removeDirAll directory

/-- Copy one file, creating the destination's parents. Byte copy, not text: fixture bytes are the
test input and a decode pass would be a rewrite. -/
public def copyFile (source destination : System.FilePath) : IO Unit := do
  if let some parent := destination.parent then
    IO.FS.createDirAll parent
  IO.FS.writeBinFile destination (← IO.FS.readBinFile source)

/-- Copy a directory tree, skipping build state and version control internals (`skip` names are
matched against each entry's file name). -/
public partial def copyTree (source destination : System.FilePath)
    (skip : Array String := #[".lake", ".git", ".lean-fmt-cache"]) : IO Unit := do
  for entry in (← source.readDir) do
    unless skip.contains entry.fileName do
      if (← entry.path.isDir) then
        copyTree entry.path (destination / entry.fileName) skip
      else
        copyFile entry.path (destination / entry.fileName)

/-- `rm -rf`: absent is fine. Suites clean state that may not exist yet. -/
public def removeDirAll? (path : System.FilePath) : IO Unit := do
  if ← path.pathExists then
    IO.FS.removeDirAll path

/-- A file's SHA-256 as lowercase hex, via the platform tool: the harness compares file bytes
across edits, and an external digest doubles as a cross-check on the comparison. -/
public def sha256 (path : System.FilePath) : IO String := do
  let result ← runProc "shasum" #["-a", "256", path.toString]
  ensure (result.exitCode == 0) s!"shasum failed on {path}: {result.stderr}"
  match result.stdout.splitOn " " with
  | hex :: _ => return hex
  | [] => throw <| IO.userError s!"shasum produced no digest for {path}"

/-- Write a file, creating its parents. -/
public def writeFile (path : System.FilePath) (contents : String) : IO Unit := do
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  IO.FS.writeFile path contents

end LeanFmt.Test
