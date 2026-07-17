import Lake

open Lake DSL System

package «lean-fmt» where
  version := v!"0.1.0"

@[default_target]
lean_exe «lean-fmt» where
  root := `Main
  supportInterpreter := true
  weakLinkArgs := #["-lLake"]

/- This library is what gets linked into every compilation of every module of an integrating project,
so its member list is that project's exposure to the formatter. `LeanFmt.Rules` was in it and is not
any more: nothing here imports it, and while it was listed, editing a rule's message text rebuilt the
plugin, invalidated every integrated module's Lake trace, and changed the compiled bytes of any
module that had a finding — `notes/01-rule-facts.md` §3 measured all three. The import graph alone was
never enough to prevent that; this list is the other half of the same boundary. -/
lean_lib LeanFmtCompilerPlugin where
  roots := #[`LeanFmtCompilerPlugin]
  globs := #[
    Glob.one `LeanFmtCompilerPlugin,
    Glob.one `LeanFmt.CompilerPlugin,
    Glob.one `LeanFmt,
    Glob.one `LeanFmt.Basic,
    Glob.one `LeanFmt.Digest,
    Glob.one `LeanFmt.ArtifactModel,
    Glob.one `LeanFmt.LosslessSource
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
    Glob.one `LeanFmt.Service,
    Glob.one `LeanFmt.Application,
    Glob.one `LeanFmt.Cli
  ]

/- The plugin shared library deliberately bundles the small semantic core at the process boundary.
This later declaration remains the canonical owner for ordinary application imports, so changing
application orchestration cannot invalidate compiler-integrated project modules.

`LeanFmt.Doc`, `LeanFmt.Comments`, and `LeanFmt.Printer` are deliberately *not* in the plugin library
above. The plugin runs inside every compilation of every downstream module, so its surface is the
semantic core and nothing else; layout is a consumer of the projection, never a producer of it. Nothing
the compiler does needs to render a document, and `LeanFmt.Printer` is the sharpest case: it exists to
turn a finished projection back into text, which is the one thing the compiler has no use for. -/
lean_lib LeanFmtCore where
  roots := #[`LeanFmt]
  globs := #[
    Glob.one `LeanFmt,
    Glob.one `LeanFmt.Basic,
    Glob.one `LeanFmt.Digest,
    Glob.one `LeanFmt.ArtifactModel,
    Glob.one `LeanFmt.LosslessSource,
    Glob.one `LeanFmt.Rules,
    Glob.one `LeanFmt.Doc,
    Glob.one `LeanFmt.Comments,
    Glob.one `LeanFmt.Printer
  ]

lean_exe «lean-fmt-tests» where
  root := `LeanFmtTest
  supportInterpreter := true

lean_exe artifactExtractor where
  root := `LeanFmtArtifactExtract
  exeName := "lean-fmt-artifact-extract"
  supportInterpreter := true

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

lean_lib BrokenCompilerFixtures where
  srcDir := "tests/compiler"
  roots := #[`Broken]
  plugins := #[`@/LeanFmtCompilerPlugin:shared]

/- `Layout` is lint-clean and deliberately not canonically laid out: `namespace     Alpha` is five
spaces where `LeanFmt.Printer` renders one (`Printer.lean:511-515`, citing `Command.lean:317-318`).
It is the one fixture that separates "has no findings" from "needs no formatting", which is the
distinction `RFP-SPEC` exists to name. -/
lean_lib CheckFixtures where
  srcDir := "tests/check"
  roots := #[`Clean, `Findings, `Layout]
  plugins := #[`@/LeanFmtCompilerPlugin:shared]

lean_lib BrokenCheckFixtures where
  srcDir := "tests/check"
  roots := #[`MalformedHeader, `UnresolvedImport]
