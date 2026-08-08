import Lake
open Lake DSL

package fixture

-- A required package nothing imports, so Lake never builds its library and
-- `<dep>/.lake/build/lib/lean` never exists -- while staying on the workspace's `LEAN_PATH`.
--
-- This reproduces mathlib's `Cli` dependency, and it is a regression fixture, not decoration.
-- `RCI-FINAL` measured mathlib and found *zero* cache entries ever written on a project with 8,276
-- built modules: `IO.FS.realPath` threw on that one absent directory, the exception escaped into
-- `ResultCache.open?`'s catch-all, and the cache silently disabled itself for the whole project.
-- With this `require` in place, every section of the cache suite runs with an absent search-path root, so
-- any regression turns the entire file red rather than needing its own assertion.
require dep from ".." / "dep"

@[default_target]
lean_lib Fixture where
  globs := #[Glob.submodules `Fixture]
