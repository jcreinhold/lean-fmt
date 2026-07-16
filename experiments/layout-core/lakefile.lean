import Lake

open Lake DSL

package «layout-core»

/- The two candidate models and the trivia probe. They are separate roots because they must be able
to disagree: neither candidate imports the other. -/
lean_lib Candidates where
  roots := #[`Wadler, `Oppen, `TriviaProbe]

/- One executable with subcommands, so a measurement compares both candidates on the same input in
the same process and the same heap. -/
@[default_target]
lean_exe «layout-probe» where
  root := `LayoutProbe
  supportInterpreter := true
