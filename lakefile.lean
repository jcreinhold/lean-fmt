import Lake

open Lake DSL System

/- The drivers are Lake's own protocol for "run this project's tests" and "run this project's linter".
Configuring them here means `lake test` and `lake lint` work in this repository, and that a consuming
project can copy a working example rather than a printed instruction. `leanprover/lean-action` probes
`lake check-lint` and runs `lake lint` when it succeeds, so this is also the CI integration.

Both driver names need guillemets. `lean-fmt` is not a legal Lean identifier, and Lake resolves a
driver by `String.toName`, so the bare spelling does not find the executable — `tests/downstream/run.sh`
§5 pins the consuming form, which needs them in the package half too. -/
package «lean-fmt» where
  version := v!"0.1.0"
  testDriver := "«test-suites»"
  lintDriver := "«lean-fmt»"
  lintDriverArgs := #["check"]

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
    Glob.one `LeanFmt.SyntaxArtifact,
    Glob.one `LeanFmt.ArtifactModel,
    Glob.one `LeanFmt.LosslessSource
  ]

lean_lib LeanFmtApplication where
  roots := #[`LeanFmt.Application]
  globs := #[
    Glob.one `LeanFmt.ArtifactStore,
    Glob.one `LeanFmt.Analysis,
    Glob.one `LeanFmt.Comments,
    Glob.one `LeanFmt.Cache,
    -- The currency decision `LeanFmt.Cache` and `LeanFmt.Application` both call, and
    -- `LeanFmt.Cache.Spec` proves about. It is here, not in `LeanFmtCacheSpec`, because it is
    -- production code: the proof library stays out of the binary, the decision does not.
    Glob.one `LeanFmt.Cache.Decision,
    Glob.one `LeanFmt.Config,
    Glob.one `LeanFmt.Discovery,
    Glob.one `LeanFmt.Doc,
    Glob.one `LeanFmt.Edit,
    Glob.one `LeanFmt.Formatter,
    Glob.one `LeanFmt.Formatter.Command,
    Glob.one `LeanFmt.Formatter.NativeLayout,
    Glob.one `LeanFmt.Formatter.Trivia,
    Glob.one `LeanFmt.GitSelection,
    Glob.one `LeanFmt.Project,
    Glob.one `LeanFmt.Semantic,
    Glob.one `LeanFmt.SyntaxArtifact,
    Glob.one `LeanFmt.Validator,
    Glob.one `LeanFmt.LanguageServer,
    Glob.one `LeanFmt.Watch,
    Glob.one `LeanFmt.Application,
    Glob.one `LeanFmt.Cli
  ]

/- The plugin shared library deliberately bundles the small semantic core at the process boundary.
This later declaration remains the canonical owner for ordinary application imports, so changing
application orchestration cannot invalidate compiler-integrated project modules.

`LeanFmt.Doc`, `LeanFmt.Comments`, and `LeanFmt.Formatter` are deliberately *not* in the plugin library
above. The plugin runs inside every compilation of every downstream module, so its surface is the
semantic core and nothing else; layout is an application-only frontend capability. -/
lean_lib LeanFmtCore where
  roots := #[`LeanFmt]
  globs := #[
    Glob.one `LeanFmt,
    Glob.one `LeanFmt.Basic,
    Glob.one `LeanFmt.Digest,
    Glob.one `LeanFmt.SyntaxArtifact,
    Glob.one `LeanFmt.ArtifactModel,
    Glob.one `LeanFmt.LosslessSource,
    Glob.one `LeanFmt.Rules,
    Glob.one `LeanFmt.Imports
  ]

/- The `RCI-MODEL` proof library. It has its own target, and is globbed explicitly and alone, for the
same reason `LeanFmt.Rules` was removed from the plugin target: Lake links every module a library
globs, imported or not. Nothing in the shipped binary or the compiler plugin imports
`LeanFmt.Cache.Spec`, and nothing globs it alongside them, so the model cannot reach either link
closure. A proof about the cache must not be able to rebuild an integrating project.

It *is* a default target, so `lake build` builds it and a proof that stops compiling fails the build
that broke it. A proof library that only builds when someone names it is a proof library that silently
rots. Being a default target does not put it in any link closure — that follows the executable's
import graph, and nothing imports this.

The `#print axioms` audit is **not** in the module; its output is recorded in `results/02-model.md`
and re-running it is a manual step before marking a claim verified. That is a real reduction in
enforcement over keeping it inline: an assumption introduced later will not announce itself in the
build that introduced it. -/
@[default_target]
lean_lib LeanFmtCacheSpec where
  roots := #[`LeanFmt.Cache.Spec]
  globs := #[Glob.one `LeanFmt.Cache.Spec]

/- The shared test harness: assertions, process spawning, golden files, JSON projection, and
filesystem fixtures for both the unit tier (`tests/Unit`) and the per-suite executables
(`tests/Suites`). A library rather than part of each executable's root so the harness compiles
once and the suite executables stay thin. Nothing in the product imports it. -/
lean_lib TestSupport where
  srcDir := "tests"
  roots := #[`Test]
  globs := #[
    Glob.one `Test,
    Glob.one `Test.Harness,
    Glob.one `Test.Proc,
    Glob.one `Test.Golden,
    Glob.one `Test.Json,
    Glob.one `Test.Fixture,
    Glob.one `Test.LspClient
  ]

/- The suite orchestrator and the package's testDriver: `lake test` runs the unit tier in-process
and then every non-slow registered suite as an executable. See `tests/Test/Runner.lean`. -/
lean_exe «test-suites» where
  srcDir := "tests"
  root := `Test.Runner
  supportInterpreter := true

/- The boundary suite: repo hygiene (module headers, tracked artifacts, the plugin import and
link-closure boundaries). Pure reads against the tracked tree, so it runs in the parallel lane. -/
lean_exe «suite-boundary» where
  srcDir := "tests"
  root := `Suites.Boundary
  supportInterpreter := true

/- The discovery suite (ruff-13): hierarchical configuration discovery on synthetic project
trees in a temp dir -- nesting, extend, symlinks, ignore sources, force-exclude, migration,
determinism, and the 1,200-file timing bound. -/
lean_exe «suite-discovery» where
  srcDir := "tests"
  root := `Suites.Discovery
  supportInterpreter := true

/- The catalog suite (ruff-12): every live rule's documented example runs against the product,
plus the explain lifecycle contract and the generated-docs drift/link checks. Clears the root
cache; workspace lane. -/
lean_exe «suite-catalog» where
  srcDir := "tests"
  root := `Suites.Catalog
  supportInterpreter := true

/- The machine-readable report formats (ruff-15): flag surface, alias/golden equivalence,
format-independent exit codes, concise/github/sarif/junit, output files, broken pipe, stdin, and
URI encoding. Populates the root cache; workspace lane. -/
lean_exe «suite-reporting» where
  srcDir := "tests"
  root := `Suites.Reporting
  supportInterpreter := true

/- The lossless projection corpus and its mutation battery; carries the independent
`Test.Projection` oracle. -/
lean_exe «suite-lossless» where
  srcDir := "tests"
  root := `Suites.Lossless
  supportInterpreter := true

/- The validator suite: admission proof, eight candidate.py gate rejections, the malformed and
throwing refusals, and the absorbed validator-map-negative defects. -/
lean_exe «suite-validator» where
  srcDir := "tests"
  root := `Suites.Validator
  supportInterpreter := true

/- The import-rule suite: FMT003/004/005, the organizer, and the fix/format split, editing
committed fixtures in place (restored via cp -p). Clears the root cache; workspace lane. -/
lean_exe «suite-imports» where
  srcDir := "tests"
  root := `Suites.Imports
  supportInterpreter := true

/- The syntax-tier rule suite: the FMT006-FMT011 matrix against the exact frontend. Clears the
root .lean-fmt-cache; workspace lane. -/
lean_exe «suite-syntax» where
  srcDir := "tests"
  root := `Suites.Syntax
  supportInterpreter := true

/- The suppression suite: source-suppression acceptance over committed fixtures. Clears the root
.lean-fmt-cache in its preamble, so it serializes with the other workspace-touching suites. -/
lean_exe «suite-suppression» where
  srcDir := "tests"
  root := `Suites.Suppression
  supportInterpreter := true

/- The format-suppression suite: format-ignore-next unit copying, CRLF identity, FMT901s, the
EOF comment. Temp setups only; parallel. -/
lean_exe «suite-format-suppression» where
  srcDir := "tests"
  root := `Suites.FormatSuppression
  supportInterpreter := true

/- The comments suite: actual-syntax ownership counts and digests, CRLF stability, comment layout
at three widths. Temp setups and scratch fixtures only; parallel. -/
lean_exe «suite-comments» where
  srcDir := "tests"
  root := `Suites.Comments
  supportInterpreter := true

/- The layout suite: comment ownership over the production corpus, absorbing the doc-properties
and comment-summary subcommands. Read-only against the workspace; parallel. -/
lean_exe «suite-layout» where
  srcDir := "tests"
  root := `Suites.Layout
  supportInterpreter := true

/- The application-formatter suite: preview/diff/cache/publication through the real binary.
Scratch-dir fixtures only; parallel. -/
lean_exe «suite-application-formatter» where
  srcDir := "tests"
  root := `Suites.ApplicationFormatter
  supportInterpreter := true

/- The style suite: the matrix/doc gate, the oracle-admitted frozen candidate, and the safe and
literal fixed points. Temp setups only; parallel. -/
lean_exe «suite-style» where
  srcDir := "tests"
  root := `Suites.Style
  supportInterpreter := true

/- The module-formatter suite: whole-module draft tiling. Builds two fixture libraries into the
main workspace -- additive and idempotent, so the parallel lane admits it; the exclusive compiler
suite is what owns LocalSyntax facet state. -/
lean_exe «suite-module-formatter» where
  srcDir := "tests"
  root := `Suites.ModuleFormatter
  supportInterpreter := true

/- The term-formatter suite: term reflow at four widths. Temp setup only; parallel. -/
lean_exe «suite-term-formatter» where
  srcDir := "tests"
  root := `Suites.TermFormatter
  supportInterpreter := true

/- The declaration-formatter suite: declaration families at four widths. Temp setups; parallel. -/
lean_exe «suite-declaration-formatter» where
  srcDir := "tests"
  root := `Suites.DeclarationFormatter
  supportInterpreter := true

/- The command-formatter suite: command boundaries at three widths plus the self-module draft.
Temp setups only; parallel. -/
lean_exe «suite-command-formatter» where
  srcDir := "tests"
  root := `Suites.CommandFormatter
  supportInterpreter := true

/- The collection-formatter suite: collection layouts at four widths. Temp setup only; parallel. -/
lean_exe «suite-collection-formatter» where
  srcDir := "tests"
  root := `Suites.CollectionFormatter
  supportInterpreter := true

/- The compiler facet suite: builds main-workspace targets, edits LeanFmt/ sources in place, and
corrupts and rebuilds .lake outputs. Exclusive lane -- nothing else may run against this workspace
meanwhile. -/
lean_exe «suite-compiler» where
  srcDir := "tests"
  root := `Suites.Compiler
  supportInterpreter := true

/- The cache suite: entry-granularity invalidation over the self-contained fixture project. It
rebuilds that project's Lake workspace, edits and restores its sources, and stamps the main
binary's mtime, so it serializes with every other workspace-touching suite. -/
lean_exe «suite-cache» where
  srcDir := "tests"
  root := `Suites.Cache
  supportInterpreter := true

/- The block-formatter suite: exact-frontend renders of the block fixture at four widths. Temp
setup file only; parallel lane. -/
lean_exe «suite-block-formatter» where
  srcDir := "tests"
  root := `Suites.BlockFormatter
  supportInterpreter := true

/- The incremental-analyzer suite: the persistent frontend session contract over a temp setup
file. Reads the workspace but builds and writes nothing in it; parallel lane. -/
lean_exe «suite-incremental» where
  srcDir := "tests"
  root := `Suites.Incremental
  supportInterpreter := true

/- The LSP acceptance run, compiled rather than interpreted: `Lean.Data.Lsp.Ipc` is the client,
and an interpreted generic against compiled library code does not link. A slow-lane suite; the
orchestrator picks it up when it exists. -/
lean_exe «suite-lsp-acceptance» where
  srcDir := "tests"
  root := `Lsp.Acceptance
  supportInterpreter := true

/- The unit tier: `LeanFmtTest.lean` split into per-domain modules under `tests/Test/Unit`, run by
the shared harness. The executable's import closure, not a glob, determines what it builds. -/
lean_exe «lean-fmt-tests» where
  srcDir := "tests"
  root := `Test.Unit
  supportInterpreter := true

lean_exe artifactExtractor where
  root := `LeanFmtArtifactExtract
  exeName := "lean-fmt-artifact-extract"
  supportInterpreter := true

/- Structural checks on this package's own module layout. Deliberately not a default target: it reads
the workspace and never contributes to it, so an ordinary `lake build` must not pay for it. -/
lean_exe «check-modules» where
  srcDir := "scripts"
  root := `CheckModules
  supportInterpreter := true
  -- Executables that import Lake must link it explicitly, as `lean-fmt` does.
  weakLinkArgs := #["-lLake"]

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
  roots := #[`LocalSyntax, `ArtifactLayout]
  plugins := #[`@/LeanFmtCompilerPlugin:shared]

lean_lib BrokenCompilerFixtures where
  srcDir := "tests/compiler"
  roots := #[`Broken]
  plugins := #[`@/LeanFmtCompilerPlugin:shared]

/- `Layout` is lint-clean and deliberately not canonically laid out: `namespace     Alpha` is five
spaces where the frontend-native formatter renders one.
It is the one fixture that separates "has no findings" from "needs no formatting", which is the
distinction `RFP-SPEC` exists to name. -/
lean_lib CheckFixtures where
  srcDir := "tests/check"
  roots := #[`Clean, `Findings, `Layout]
  plugins := #[`@/LeanFmtCompilerPlugin:shared]

lean_lib BrokenCheckFixtures where
  srcDir := "tests/check"
  roots := #[`MalformedHeader, `UnresolvedImport]

/- Imported open syntax for the actual-node formatter adapter contract. This is a fixture library,
not part of the application or compiler-plugin link closure. -/
lean_lib FormatterAdapterFixtures where
  srcDir := "tests/formatter-adapter"
  roots := #[`AdapterSyntax]

/- The native grammar adapter's four invariant families, one module each: positional terminal
alignment, comment ownership at every boundary, typed exact islands, and offside carriers. They are
declared modules rather than generated buffers because each has to reach the adapter through the same
exact Lake setup a project file does, and because `tests/native-layout/run.sh` formats them and then
formats the result again -- an idempotence claim needs a module the frontend can elaborate twice.

They are deliberately *not* canonically laid out; that is the input the suite reflows. `lean-fmt.toml`
still lints them, and that is intended: they are valid, finding-free Lean, and layout is not a rule. -/
lean_lib NativeLayoutFixtures where
  srcDir := "tests/native-layout"
  roots := #[`Alignment, `Boundaries, `Islands, `Offside]
  plugins := #[`@/LeanFmtCompilerPlugin:shared]
