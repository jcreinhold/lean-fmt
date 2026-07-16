import Lake

open Lake DSL System

package «lean-fmt» where
  version := v!"0.1.0"

@[default_target]
lean_exe «lean-fmt» where
  root := `Main
  supportInterpreter := true
  weakLinkArgs := #["-lLake"]

lean_lib LeanFmtCompilerPlugin where
  roots := #[`LeanFmtCompilerPlugin]
  globs := #[
    Glob.one `LeanFmtCompilerPlugin,
    Glob.one `LeanFmt.CompilerPlugin,
    Glob.one `LeanFmt,
    Glob.one `LeanFmt.Basic,
    Glob.one `LeanFmt.Digest,
    Glob.one `LeanFmt.ArtifactModel,
    Glob.one `LeanFmt.Rules
  ]

lean_lib LeanFmtApplication where
  roots := #[`LeanFmt.Application]
  globs := #[
    Glob.one `LeanFmt.ArtifactStore,
    Glob.one `LeanFmt.Analysis,
    Glob.one `LeanFmt.Cache,
    Glob.one `LeanFmt.Config,
    Glob.one `LeanFmt.Edit,
    Glob.one `LeanFmt.Project,
    Glob.one `LeanFmt.Semantic,
    Glob.one `LeanFmt.Application,
    Glob.one `LeanFmt.Cli
  ]

/- The plugin shared library deliberately bundles the small semantic core at the process boundary.
This later declaration remains the canonical owner for ordinary application imports, so changing
application orchestration cannot invalidate compiler-integrated project modules. -/
lean_lib LeanFmtCore where
  roots := #[`LeanFmt]
  globs := #[
    Glob.one `LeanFmt,
    Glob.one `LeanFmt.Basic,
    Glob.one `LeanFmt.Digest,
    Glob.one `LeanFmt.ArtifactModel,
    Glob.one `LeanFmt.Rules
  ]

lean_exe «lean-fmt-tests» where
  root := `LeanFmtTest
  supportInterpreter := true

lean_exe artifactExtractor where
  root := `LeanFmtArtifactExtract
  exeName := "lean-fmt-artifact-extract"
  supportInterpreter := true

private def trailingWhitespaceEnabled : Bool :=
  (get_config? leanFmtTrailingWhitespace).bind envToBool? |>.getD true

private def artifactFile (mod : Module) : FilePath :=
  Lean.modToFilePath (mod.pkg.buildDir / "lean-fmt-artifacts") mod.name "json"

private def artifactQueryJson (artifact : Artifact) : Lean.Json :=
  Lean.Json.mkObj [
    ("hash", .str artifact.hash.toString),
    ("ext", .str artifact.ext),
    ("path", .str artifact.path.toString)
  ]

local instance : QueryJson Artifact := ⟨artifactQueryJson⟩

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

lean_lib CheckFixtures where
  srcDir := "tests/check"
  roots := #[`Clean, `Findings]
  plugins := #[`@/LeanFmtCompilerPlugin:shared]
  leanOptions := #[⟨`weak.leanFmt.trailingWhitespace,
    trailingWhitespaceEnabled⟩]

lean_lib BrokenCheckFixtures where
  srcDir := "tests/check"
  roots := #[`MalformedHeader, `UnresolvedImport]
