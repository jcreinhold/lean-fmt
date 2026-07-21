/-
Copyright (c) 2024 Yaël Dillies, Damiano Testa. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Yaël Dillies, Damiano Testa, Jacob Reinhold
-/
module

import all LeanFmt.Project

import Lake.Config.Package
import Lake.Load.Workspace
import Lean.Elab.ParseImportsFast
import Std.Data.HashMap
import Std.Data.HashSet

open System Lean LeanFmt.Internal

/-!
# Structural checks on the package's module layout

Taken from mathlib's `scripts/mk_all.lean`: the guarantee, and the shape of its `--check` mode. None
of its code survives. mk_all keeps `Mathlib.lean` importing every source file so that no file escapes
the build, and `--check` verifies that file is current. lean-fmt cannot generate such a file — its
four libraries are carved out of one directory by hand, `LeanFmt.lean` deliberately exports nothing,
and `lakefile.lean` records measured reasons for individual glob entries — so the guarantee is
expressed directly, as a check with no generator behind it.

A module escapes the build when no `lean_lib` glob expansion contains it and nothing that is itself
built imports it. Lake then never compiles it and `lake build` stays green while the file rots.
Measured against Lake v4.33.0-rc1: a file holding `def n : Nat := "not a Nat"`, unglobbed and
unimported, builds clean.

Two Lake predicates decide a module's fate, and conflating them gives the wrong answer.
`LeanLibConfig.isLocalModule` (root prefix **or** glob) decides whether a library *claims* a module,
which is what makes it resolvable and buildable on demand. `LeanLibConfig.isBuildableModule` decides
whether the library will build it when asked. Neither is "the library target compiles it": that is
the glob expansion alone, which is why `LeanFmt.Suppression` is in no glob yet compiles — the
executable's import closure reaches it. So the seeds below are glob expansions and executable roots,
and reachability is taken over imports from there.
-/

namespace LeanFmt.CheckModules

/-- A module some rule objects to. `detail` states the defect in that rule's own terms, because the
rule is the only thing that knows why its subject is wrong. -/
private structure Violation where
  subject : Name
  detail : String

/-- Everything a rule is allowed to know, resolved once.

Rules are pure functions over this record. That is the design and not an incidental choice: a rule
cannot read the filesystem, cannot start a Lake build, and cannot depend on what happens to be built
already — so it cannot report a different answer on a clean checkout than on a warm one. Adding a
rule is a pure function plus one entry in `rules`. -/
private structure Layout where
  /-- Package source modules, from `Project`'s complete non-`.lake` selection. -/
  sources : Array Name
  /-- Modules a declared target compiles outright: a `lean_lib` glob expansion, or a `lean_exe` root.
  Everything else reaches the build only by being imported from one of these. -/
  seeds : Array Name
  /-- Intra-package import edges, header only. Imports outside the package are dropped: no rule here
  can have an opinion about them, and keeping them would walk the closure into the toolchain. -/
  importsOf : Std.HashMap Name (Array Name)
  /-- Modules whose header would not parse, and which therefore contribute no edges to `importsOf`.
  Dropping their edges is the right answer to what the build compiles — a module that does not parse
  compiles nothing, and reaches nothing through itself — but it does leave the closure incomplete, so
  the run states it instead of degrading in silence. This package holds such files deliberately:
  `tests/check/MalformedHeader.lean` is a fixture for exactly that condition. -/
  unparsedHeaders : Array Name

/-- Modules the build actually compiles: the seeds, closed under imports. -/
private partial def Layout.compiled (layout : Layout) : Std.HashSet Name :=
  let rec walk (pending : List Name) (seen : Std.HashSet Name) : Std.HashSet Name :=
    match pending with
    | [] => seen
    | next :: rest =>
      if seen.contains next then
        walk rest seen
      else
        walk ((layout.importsOf.getD next #[]).toList ++ rest) (seen.insert next)
  walk layout.seeds.toList {}

/-- A structural invariant over the module layout, and the check that decides whether it holds. -/
private structure Rule where
  /-- Stable identifier; it appears in output and in whatever pins this rule's behaviour. -/
  name : String
  /-- The invariant, phrased so that a failure line reads as a breach of it. -/
  invariant : String
  run : Layout → Array Violation

/-- The one failure mode that survives measurement. Its converse — that a library artifact omits an
unglobbed import — does not exist: Lake links the import closure *and* the globs, so an unglobbed
import is still linked, and a glob adds a module nothing imports. -/
private def neverCompiled : Rule where
  name := "never-compiled"
  invariant := "every package source module is compiled by some declared Lake target"
  run := fun layout =>
    let compiled := layout.compiled
    (layout.sources.filter (!compiled.contains ·)).map fun subject =>
      { subject, detail := "in no lean_lib glob, and imported by nothing that is compiled" }

private def rules : Array Rule := #[neverCompiled]

/-- The package-internal imports a header declares, or `none` when it does not parse. -/
private def headerImports (known : Std.HashSet Name) (source relativePath : String) :
    IO (Option (Array Name)) := do
  try
    let header ← parseImports' source relativePath
    return some <| header.imports.filterMap fun imported =>
      if known.contains imported.module then some imported.module else none
  catch _ =>
    return none

/-- A resolved layout, with where its cost went. The timings sit here rather than in `Layout`
deliberately: a rule that could read a clock would no longer be a pure function of the layout. -/
private structure Resolution where
  layout : Layout
  workspaceNanos : Nat
  selectionNanos : Nat

/-- Resolve the layout. The only IO in the tool, and the only place that knows Lake exists.

Source selection goes through `Project`, which owns complete non-`.lake` selection and the exact Lake
setup for this toolchain; walking the tree here would be a second answer to a question the product
already answers once. The snapshot carries each file's bytes, so parsing headers costs no further
reads, and `parseImports'` stops at the first non-import command rather than parsing the file. -/
private def resolve (root : FilePath) : IO Resolution := do
  let snapshot ← Project.loadAll root
  let package := snapshot.workspace.root
  let modules := snapshot.targets.filterMap (·.module?.map (·.name))
  let known : Std.HashSet Name := modules.foldl (·.insert ·) {}
  let globbed := modules.filter fun name =>
    package.leanLibs.any fun lib => lib.config.globs.any (·.matches name)
  let mut importsOf : Std.HashMap Name (Array Name) := {}
  let mut unparsedHeaders : Array Name := #[]
  for target in snapshot.targets do
    if let some mod := target.module? then
      match ← headerImports known target.source target.relativePath with
      | some imports => importsOf := importsOf.insert mod.name imports
      | none => unparsedHeaders := unparsedHeaders.push mod.name
  return {
    layout := {
      sources := modules
      seeds := globbed ++ package.leanExes.map (·.config.root)
      importsOf
      unparsedHeaders
    }
    workspaceNanos := snapshot.workspaceLoadNanos
    selectionNanos := snapshot.selectionNanos
  }

private def plural (count : Nat) (noun : String) : String :=
  s!"{count} {noun}" ++ if count == 1 then "" else "s"

private def milliseconds (nanos : Nat) : String :=
  s!"{nanos / 1000000}.{(nanos / 100000) % 10} ms"

/-- Exit `0` when every rule holds, `1` when one does not, and `2` when the tool could not reach an
answer. mk_all returns `min updates 125`, which cannot distinguish a broken checker from broken code;
CI has to treat those differently. -/
private def run : IO UInt32 := do
  try
    let started ← IO.monoNanosNow
    let resolution ← resolve (← IO.currentDir)
    let layout := resolution.layout
    let resolved ← IO.monoNanosNow
    let mut failed := 0
    for rule in rules do
      let violations := rule.run layout
      if violations.isEmpty then
        IO.println s!"ok    {rule.name} — {rule.invariant}"
      else
        failed := failed + 1
        IO.println s!"FAIL  {rule.name} — {rule.invariant}"
        for violation in violations do
          IO.println s!"        {violation.subject}: {violation.detail}"
    let finished ← IO.monoNanosNow
    unless layout.unparsedHeaders.isEmpty do
      IO.println s!"\nheaders that would not parse, contributing no imports to the closure:"
      for name in layout.unparsedHeaders do
        IO.println s!"        {name}"
    IO.println s!"\n{plural layout.sources.size "module"}, {plural rules.size "rule"}; \
      resolved in {milliseconds (resolved - started)} \
      ({milliseconds resolution.workspaceNanos} Lake workspace, \
      {milliseconds resolution.selectionNanos} source selection), \
      checked in {milliseconds (finished - resolved)}"
    return if failed == 0 then 0 else 1
  catch error =>
    IO.eprintln s!"check-modules could not run: {error}"
    return 2

end LeanFmt.CheckModules

public def main : IO UInt32 := LeanFmt.CheckModules.run
