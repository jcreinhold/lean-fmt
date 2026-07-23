import Lake

open Lake DSL

package artifactSyntaxDesign

require «lean-fmt» from "../.."

@[default_target]
lean_exe artifactSyntaxProbe where
  root := `Probe
  supportInterpreter := true
  weakLinkArgs := #["-lLake"]

lean_lib OptionProbePlugin where
  roots := #[`OptionProbePlugin]

lean_lib OptionProbeFixtures where
  roots := #[`OptionFixture]
  plugins := #[`@/OptionProbePlugin:shared]
