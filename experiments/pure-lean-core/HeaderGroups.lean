module

import Lean.Elab.Frontend
import Lean.Elab.Import

open Lean System

namespace HeaderGroups

private def readPaths (root manifest : FilePath) : IO (Array FilePath) := do
  let contents ← IO.FS.readFile manifest
  return contents.splitOn "\n" |>.foldl (init := #[]) fun paths line =>
    if line.isEmpty then paths else paths.push (root / line)

private def contextKey (path : FilePath) : IO String := do
  let source ← IO.FS.readFile path
  let input := Parser.mkInputContext source path.toString
  let (header, _, messages) ← Parser.parseHeader input
  if messages.hasErrors then
    throw <| IO.userError s!"header parse failed: {path}"
  let header : Elab.HeaderSyntax := header
  return (toJson header.toModuleHeader).compress

private def usage := "usage: header-groups MATHLIB_ROOT SOURCE_MANIFEST"

private def run (args : List String) : IO UInt32 := do
  let [rootArg, manifestArg] := args
    | IO.eprintln usage
      return 2
  let root : FilePath := rootArg
  let manifest : FilePath := manifestArg
  let paths ← readPaths root manifest
  let started ← IO.monoNanosNow
  let mut counts : Std.HashMap String Nat := {}
  for path in paths do
    let key ← contextKey path
    counts := counts.alter key fun count? => some (count?.getD 0 + 1)
  let mut singletonContexts := 0
  let mut maxGroup := 0
  let mut reusableFiles := 0
  let mut histogram : Std.TreeMap Nat Nat := {}
  for (_, count) in counts do
    if count == 1 then
      singletonContexts := singletonContexts + 1
    else
      reusableFiles := reusableFiles + count - 1
    maxGroup := max maxGroup count
    histogram := histogram.alter count fun groups? => some (groups?.getD 0 + 1)
  let elapsedMs := ((← IO.monoNanosNow) - started) / 1000000
  IO.println s!"files={paths.size}"
  IO.println s!"ordered_header_contexts={counts.size}"
  IO.println s!"singleton_contexts={singletonContexts}"
  IO.println s!"reusable_files_after_first={reusableFiles}"
  IO.println s!"max_group_size={maxGroup}"
  for (size, groups) in histogram do
    IO.println s!"group_size={size} groups={groups}"
  IO.println s!"phase.header_grouping_ms={elapsedMs}"
  return 0

end HeaderGroups

public def main (args : List String) : IO UInt32 := HeaderGroups.run args
