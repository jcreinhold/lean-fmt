import Lake

open Lake DSL System

package «lean-fmt» where
  version := v!"0.1.0"

@[default_target]
lean_exe «lean-fmt» where
  root := `Main

lean_lib LeanFmtCompilerPlugin where
  roots := #[`LeanFmtCompilerPlugin]
  globs := #[Glob.one `LeanFmtCompilerPlugin, Glob.one `LeanFmt, Glob.submodules `LeanFmt]

lean_exe «lean-fmt-tests» where
  root := `LeanFmtTest

lean_exe artifactExtractor where
  root := `LeanFmtArtifactExtract
  exeName := "lean-fmt-artifact-extract"
  supportInterpreter := true

private def trailingWhitespaceEnabled : Bool :=
  (get_config? leanFmtTrailingWhitespace).bind envToBool? |>.getD true

private def artifactFile (mod : Module) : FilePath :=
  Lean.modToFilePath (mod.pkg.buildDir / "lean-fmt-artifacts") mod.name "json"

/- The compiler records the formatter payload in Lean's persistent lint log, which is serialized
inside the successful `.olean`. This facet owns both extraction from that exact module artifact and
its compact, cacheable output; no candidate file or post-hoc identity association exists. -/
module_facet leanFmtArtifact (mod : Module) : Artifact := do
  let oleanJob ← mod.olean.fetch
  let extractorJob ← artifactExtractor.fetch
  let dependency := oleanJob.zipWith (fun olean extractor => (olean, extractor)) extractorJob
  dependency.mapM fun (olean, extractor) => do
    withCurrPackage mod.pkg do
      buildArtifactUnlessUpToDate (artifactFile mod) (text := true) (ext := "json")
          (restore := true) (platformIndependent := true) do
        proc {
          cmd := extractor.toString
          args := #[mod.name.toString, olean.toString, (artifactFile mod).toString]
          env := #[
            ⟨"LEAN_PATH", (← getLeanPath).toString⟩,
            ⟨"LEAN_NUM_THREADS", "1"⟩
          ]
        }

/- A small integration library exercises plugin and facet ownership without making the formatter's
own implementation depend on itself as a compiler plugin. -/
lean_lib CompilerFixtures where
  srcDir := "tests/compiler"
  roots := #[`LocalSyntax]
  plugins := #[`@/LeanFmtCompilerPlugin:shared]
  leanOptions := #[⟨`weak.leanFmt.trailingWhitespace,
    trailingWhitespaceEnabled⟩]

lean_lib BrokenCompilerFixtures where
  srcDir := "tests/compiler"
  roots := #[`Broken]
  plugins := #[`@/LeanFmtCompilerPlugin:shared]
  leanOptions := #[⟨`weak.leanFmt.trailingWhitespace,
    trailingWhitespaceEnabled⟩]
