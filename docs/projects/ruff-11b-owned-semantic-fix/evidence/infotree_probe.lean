/-
ROS-SPEC first-hand probe: is the whole-file info tree reachable through the SAME
`Lean.Language.toSnapshotTree ... |>.getAll` walk that `analyzeExact` already runs for the
message log, via each `Snapshot.infoTree?`? And does a deprecated-declaration occurrence resolve
to `(range, declName, newName?)` from a `TermInfo` whose `expr` is a `@[deprecated]` constant?

This copies the exact-frontend core of `LeanFmt/Analysis.lean:analyzeExact` (no LeanFmt import,
so it is an independent oracle) and folds every reachable info tree.

Run: lake env lean --run docs/projects/ruff-11b-owned-semantic-fix/evidence/infotree_probe.lean
-/
import Lean
import Lean.Server.InfoUtils

open Lean Elab Language

unsafe def main : IO Unit := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let path : System.FilePath := "docs/projects/ruff-11b-owned-semantic-fix/evidence/probe_fixture.lean"
  let source ← IO.FS.readFile path
  let input := Parser.mkInputContext source path.toString
  let options := Lean.Elab.async.setIfNotSet {} true
  let setupImports (header : Elab.HeaderSyntax) := do
    return .ok {
      mainModuleName := `ProbeFixture
      isModule := header.isModule
      imports := header.imports
      opts := options
      trustLevel := 0
    }
  let context : ProcessingContext := { input with }
  let snapshot ← Lean.Language.Lean.process setupImports none context
  let tree := toSnapshotTree snapshot
  let snaps := tree.getAll
  -- (1) reachability through the existing snapshot-tree walk
  let treesWithInfo := snaps.filterMap (·.infoTree?)
  IO.println s!"snapshots={snaps.size} snapshotsWithInfoTree={treesWithInfo.size}"
  -- (2) occurrence resolution: fold each reachable info tree for deprecated const occurrences.
  -- Record which *tree index* each occurrence came from, to prove multi-command reachability
  -- (each command contributes its own info tree; a whole-file walk must surface both uses).
  -- Diagnostic: count all Info / TermInfo nodes and the distinct const names seen.
  let mut totalInfo := 0
  let mut termInfo := 0
  let mut constNames : Array String := #[]
  for t in treesWithInfo do
    let (ti2, cn2, tot2) := t.foldInfo (init := (termInfo, constNames, totalInfo))
      fun _ info (acc : Nat × Array String × Nat) =>
        let (tc, cs, tot) := acc
        match info with
        | .ofTermInfo ti =>
          match ti.expr.constName? with
          | some name => (tc + 1, cs.push name.toString, tot + 1)
          | none => (tc + 1, cs, tot + 1)
        | _ => (tc, cs, tot + 1)
    termInfo := ti2; constNames := cn2; totalInfo := tot2
  IO.println s!"totalInfoNodes={totalInfo} termInfoNodes={termInfo}"
  IO.println s!"distinctConstNames={(constNames.foldl (fun (s : Array String) n => if s.contains n then s else s.push n) #[])}"
  -- Direct check: does the FINAL environment carry the deprecation on `foo`?
  if let some cmdState := Lean.Language.Lean.waitForFinalCmdState? snapshot then
    let env := cmdState.env
    IO.println s!"finalEnv.deprecatedAttr[foo] = {(Lean.Linter.deprecatedAttr.getParam? env `foo).map (·.newName?)}"
    let mangled := (((`_private.ProbeFixture).num 0).str "foo")
    match Lean.Linter.deprecatedAttr.getParam? env mangled with
    | some entry =>
      IO.println s!"finalEnv.deprecatedAttr[{mangled}] = some (newName?={entry.newName?} since?={entry.since?} text?={entry.text?})"
    | none => IO.println s!"finalEnv.deprecatedAttr[{mangled}] = none"
  let mut occ : Array (Nat × String × Nat × Nat × String × String × Bool) := #[]
  for h : i in [0:treesWithInfo.size] do
    let t := treesWithInfo[i]!
    occ := t.foldInfo (init := occ) fun ci info acc =>
      match info with
      | .ofTermInfo ti =>
        match ti.expr.constName? with
        | some name =>
          match Lean.Linter.deprecatedAttr.getParam? ci.env name with
          | some entry =>
            match info.range? with
            | some r =>
              let nn := match entry.newName? with | some m => m.toString | none => "<none>"
              let spelled := String.fromUTF8! (source.toUTF8.extract r.start.byteIdx r.stop.byteIdx)
              acc.push (i, name.toString, r.start.byteIdx, r.stop.byteIdx, nn, spelled, ti.isBinder)
            | none => acc
          | none => acc
        | none => acc
      | _ => acc
  IO.println s!"deprecatedOccurrences={occ.size}"
  for (treeIdx, name, s, e, nn, spelled, isBinder) in occ do
    IO.println s!"  tree#{treeIdx}: {name} @ byte[{s},{e}) isBinder={isBinder} -> newName={nn} (spelled: {spelled})"
  -- Use-site occurrences after excluding binders and de-duplicating by byte range:
  let uses := occ.filter (fun o => !o.2.2.2.2.2.2)
  let distinctRanges := uses.foldl (fun (s : Array (Nat × Nat)) o =>
    let key := (o.2.2.1, o.2.2.2.1)
    if s.contains key then s else s.push key) #[]
  IO.println s!"useSiteOccurrences(non-binder)={uses.size} distinctUseRanges={distinctRanges.size} ranges={distinctRanges}"
