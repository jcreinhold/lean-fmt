import Lake
open Lake DSL

-- The `LeanFmt` Lean capability package. It builds as a shared-library capability
-- (`LeanLib.sharedFacet`) that a Lean-linked worker child loads, exposing the
-- `@[export]` worker commands (`lean_fmt_metadata`, `lean_fmt_doctor`,
-- `lean_fmt_analyze`, and `lean_fmt_validate`) rather than a subprocess dispatch loop.
-- The package depends only on Lean and leaves process policy to the Lean-free application.
package «lean-fmt» where
  version := v!"0.1.0"

@[default_target]
lean_lib LeanFmt where
  roots := #[`LeanFmt]
  globs := #[.andSubmodules `LeanFmt]
  defaultFacets := #[LeanLib.sharedFacet]
