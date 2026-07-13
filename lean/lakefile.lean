import Lake
open Lake DSL

-- The `LeanFmt` Lean capability package. It builds as a shared-library capability
-- (`LeanLib.sharedFacet`) that a Lean-linked worker child loads, exposing the
-- `@[export]` worker commands (`lean_fmt_metadata`, `lean_fmt_doctor`) rather than a
-- subprocess dispatch loop. It stays dependency-free at this stage: the identity and
-- self-check commands are plain request/response exports. The upstream `lean-rs`
-- interop streaming shims are required later, by the first streaming export (the
-- source-snapshot frontend), not by these commands.
package «lean-fmt» where
  version := v!"0.1.0"

@[default_target]
lean_lib LeanFmt where
  roots := #[`LeanFmt]
  globs := #[.andSubmodules `LeanFmt]
  defaultFacets := #[LeanLib.sharedFacet]
