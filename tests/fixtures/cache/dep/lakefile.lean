import Lake
open Lake DSL

package dep

lean_lib Dep where
  globs := #[Glob.submodules `Dep]
