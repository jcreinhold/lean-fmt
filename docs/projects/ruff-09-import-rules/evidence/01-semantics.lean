/-
RIR-SPEC import-semantics characterization. Reproduce with:

    lake env lean docs/projects/ruff-09-import-rules/evidence/01-semantics.lean

Captured output: `01-semantics.txt`. This pins the header/import facts the import-rule catalog rests
on (`notes/01-semantics.md`):

  - what `parseImports'` (Lake's own header reader) records, and what it discards;
  - that the implicit prelude injects two phantom `Init` entries the surface text never wrote, and
    that a `prelude` marker suppresses them — so the abstract import list is NOT the written header;
  - that `all` / `meta` / the `module` marker ride on the abstract `Import` as flags, so the "same"
    module under two modifiers is two different imports;
  - that `parseImports'` preserves a literal duplicate rather than collapsing it, and the frontend
    silently accepts one;
  - that the parser preserves written import order, the coordinate the environment replays.

Legacy (non-module) mode on purpose: `parseImports'` is `meta`-gated under the module system, and
this throwaway probe is not production code. It exists only to be run and read.
-/

import Lean
import Lean.Elab.ParseImportsFast

open Lean Elab

/-- Report exactly what `parseImports'` records: the module flag and each abstract `Import` with its
modifiers. This is the structure a rule built on `parseImports'` alone would see. -/
def showHeader (label input : String) : IO Unit := do
  let header ← Lean.parseImports' input "<t>"
  IO.println s!"[{label}] isModule={header.isModule} count={header.imports.size}"
  for imp in header.imports do
    IO.println s!"    module={imp.module} all={imp.importAll} exported={imp.isExported} meta={imp.isMeta}"

/-- `true` iff `input`'s bytes are accepted by the frontend (lexer + header + commands). -/
def accepted (input : String) : IO Bool := do
  let ctx := Parser.mkInputContext input "<t>"
  let (header, state, msgs) ← Parser.parseHeader ctx
  let (env, msgs) ← processHeader header {} msgs ctx
  let s ← IO.processCommands ctx state (Command.mkState env msgs {})
  return (s.commandState.messages.toList.filter (·.severity == .error)).isEmpty

#eval show IO Unit from do
  IO.println "== A. what parseImports' records =="
  -- plain duplicate: the same module written twice
  showHeader "dup-plain" "import Lean.Data.Json\nimport Lean.Data.Json"
  -- same module, different modifier: NOT the same abstract import
  showHeader "all-vs-plain" "module\nimport Lean.Data.Json\nimport all Lean.Data.Json"
  showHeader "meta-vs-plain" "module\nmeta import Lean.Data.Json\nimport Lean.Data.Json"
  -- the module marker flips the default export flag of written imports
  showHeader "module-marker" "module\nimport Lean.Data.Json"
  showHeader "no-module-marker" "import Lean.Data.Json"
  -- the implicit prelude injects phantom Init; a `prelude` marker suppresses it
  showHeader "prelude" "prelude\nimport Lean.Data.Json"
  showHeader "no-prelude" "import Lean.Data.Json"

  IO.println "== B. frontend acceptance of a literal duplicate =="
  IO.println s!"dup accepted    = {← accepted "import Lean.Data.Json\nimport Lean.Data.Json"}"
  IO.println s!"single accepted = {← accepted "import Lean.Data.Json"}"

  IO.println "== C. does parseImports' collapse a duplicate? =="
  let dupHeader ← Lean.parseImports' "import Lean.Data.Json\nimport Lean.Data.Json" "<t>"
  IO.println s!"parseImports' count on a written duplicate = {dupHeader.imports.size}"

  IO.println "== D. is written import order preserved? =="
  -- Order the surface text as C, A, B; read back the *written* (non-phantom) modules in order.
  let ordered ← Lean.parseImports' "import Lean.Data.Json\nimport Lean.Data.HashMap\nimport Lean.Data.RBMap" "<t>"
  let written := ordered.imports.filter (fun imp => imp.module != `Init)
  IO.println s!"written order = {written.map (·.module)}"
