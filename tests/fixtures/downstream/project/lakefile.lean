import Lake
open Lake DSL

/- The downstream-integration fixture. It stands in for a project that consumes `lean-fmt` the way a
user would: by `require`, not from inside the repository's own workspace.

Three claims are under test here and nowhere else. The executable resolves across packages, so
`lake exe lean-fmt` reaches a dependency's binary. The `leanFmtArtifact` module facet, declared in the
dependency's lakefile, registers in *this* workspace. And the plugin set at package level reaches
every module without touching a single `lean_lib`. -/
package consumer where
  plugins := #[`@«lean-fmt»/LeanFmtCompilerPlugin:shared]
  lintDriver := "«lean-fmt»/«lean-fmt»"
  lintDriverArgs := #["check"]

require «lean-fmt» from ".." / ".." / ".." / ".."

@[default_target]
lean_lib Consumer where
  globs := #[Glob.submodules `Consumer]
