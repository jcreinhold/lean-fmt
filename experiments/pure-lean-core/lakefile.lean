import Lake

open Lake DSL

package «pure-lean-core»

lean_lib LeanFmt where
  srcDir := "../../crates/lean-fmt/lean"
  roots := #[`LeanFmt.Frontend]

lean_lib LeanFmtProbePlugin

@[default_target]
lean_exe «pure-lean-core» where
  root := `Main
  supportInterpreter := true
  weakLinkArgs := #["-lLake"]

lean_exe «pure-lean-analyze» where
  root := `AnalyzeMain
  supportInterpreter := true
  weakLinkArgs := #["-lLake"]
