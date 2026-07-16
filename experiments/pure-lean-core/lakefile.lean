import Lake

open Lake DSL

package «pure-lean-core»

lean_lib LeanFmtProbePlugin

lean_lib ExactReuseFixtures where
  roots := #[`ExactReuseFixtures.State]

@[default_target]
lean_exe «pure-lean-core» where
  root := `Main
  supportInterpreter := true
  weakLinkArgs := #["-lLake"]

lean_exe «pure-lean-analyze» where
  root := `AnalyzeMain
  supportInterpreter := true
  weakLinkArgs := #["-lLake"]

lean_exe «header-groups» where
  root := `HeaderGroups

lean_exe «setup-audit» where
  root := `SetupAudit
  supportInterpreter := true
  weakLinkArgs := #["-lLake"]

lean_exe «module-evidence» where
  root := `ModuleEvidence
  supportInterpreter := true
  weakLinkArgs := #["-lLake"]
