import Lake

open Lake DSL

package «lossless-source»

@[default_target]
lean_exe «round-trip» where
  root := `RoundTrip
  supportInterpreter := true

/- The probe observes losslessness from inside the compiler, where the token table already contains
the file's own syntax declarations. -/
lean_lib ProbePlugin where
  roots := #[`ProbePlugin]

lean_lib ProbeFixtures where
  srcDir := "fixtures"
  roots := #[`Trivia, `Tokens, `Syntax]
  plugins := #[`@/ProbePlugin:shared]
