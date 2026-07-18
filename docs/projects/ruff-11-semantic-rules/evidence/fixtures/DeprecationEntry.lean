-- Proves the OWNED substrate for a future FMT014 autofix: the structured
-- replacement/since/text are queryable from Environment data (not parsed from text).
import Lean
open Lean Linter

def newName : Nat := 1
@[deprecated newName (since := "2024-01-01")]
def oldName : Nat := 0

open Lean Elab Command in
run_cmd do
  let env ← getEnv
  match deprecatedAttr.getParam? env `oldName with
  | some e => logInfo s!"newName?={e.newName?} since?={e.since?} text?={e.text?}"
  | none   => logInfo "no deprecation entry"
