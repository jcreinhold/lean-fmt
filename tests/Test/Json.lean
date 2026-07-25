module

import Test.Harness

public import Lean.Data.Json

/-!
# JSON assertions

The shell suites asserted over `--json` output with inline Python (`data["files"][0]["findings"]
== …`, two hundred and thirty-one times across the corpus). The assertions were fine; the medium
was a third implementation language. `jsonAt?` walks a path of fields and indices; `ensureJsonAt`
pins the value at the end of one, rendering the path so a failure says *where* the report changed
shape, which is the question a JSON regression always asks first.
-/

namespace LeanFmt.Test

/-- One step into a JSON value: an object field or an array index. -/
public inductive JsonStep where
  | field (name : String)
  | index (position : Nat)

/-- Render a path the way the Python heredocs wrote it: `files[0].findings`. -/
private def JsonStep.render : List JsonStep → String
  | [] => "<root>"
  | .field name :: rest => "." ++ name ++ renderCont rest
  | .index position :: rest => s!"[{position}]" ++ renderCont rest
where
  renderCont : List JsonStep → String
    | [] => ""
    | .field name :: rest => "." ++ name ++ renderCont rest
    | .index position :: rest => s!"[{position}]" ++ renderCont rest

/-- Walk `path` from `json`, returning `none` at the first step that does not exist. -/
public def jsonAt? (json : Lean.Json) (path : List JsonStep) : Option Lean.Json :=
  path.foldlM (init := json) fun current step =>
    match step with
    | .field name => (current.getObjVal? name).toOption
    | .index position => (current.getArr?).toOption >>= (·[position]?)

/-- Parse `text` as JSON or fail the test with `label` naming what was being parsed — a suite that
fed the binary bad flags should hear "check --json did not emit JSON", not a raw parse error. -/
public def parseJson (text : String) (label : String) : IO Lean.Json :=
  match Lean.Json.parse text with
  | .ok json => pure json
  | .error error => throw <| IO.userError s!"{label}: output is not JSON: {error}\n{text}"

/-- Assert the value at `path` equals `expected`. A missing path and a wrong value are the same
failure class here: the report stopped containing what the suite recorded. -/
public def ensureJsonAt (json : Lean.Json) (path : List JsonStep) (expected : Lean.Json)
    (message : String := "") : IO Unit := do
  let location := JsonStep.render path
  match jsonAt? json path with
  | none =>
    throw <| IO.userError s!"{message}{if message.isEmpty then "" else ": "}path {location} \
      does not exist in:\n{json.pretty}"
  | some actual =>
    unless actual == expected do
      throw <| IO.userError s!"{message}{if message.isEmpty then "" else ": "}value at \
        {location}\n  expected: {expected.compress}\n  actual:   {actual.compress}"

end LeanFmt.Test
