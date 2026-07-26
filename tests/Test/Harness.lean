module

/-!
# Test harness core

The assertion style and the runner every native test executable in this package shares. Before this
library existed, `LeanFmtTest.lean` threw on the first failing `ensure` and the thirty-odd test
functions behind it became invisible; every shell suite re-implemented the same `ok`/`FAIL` printing
in bash. One failure here costs exactly one test: the runner catches it, prints it next to the
test's name, keeps going, and sets the exit code at the end.

A `Case` is deliberately a bare `IO Unit` rather than a framework monad. The tests it runs are
already written against `IO`, and a wrapper that bought only naming would tax every suite for a
feature the runner can provide from the outside.
-/

namespace LeanFmt.Test

/-- One named test. `run` fails the test by throwing; anything it prints goes to the suite's log,
not the summary line. -/
public structure Case where
  name : String
  run : IO Unit

/-- The assertion every test in the package is phrased in: fail with `message` unless `condition`. -/
public def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do
    throw <| IO.userError message

/-- Equality assertion that prints both sides on failure, so a regression names the drift instead
of naming the line number of the `ensure`. -/
public def ensureEq [BEq α] [Repr α] (label : String) (expected actual : α) : IO Unit := do
  unless actual == expected do
    throw <| IO.userError s!"{label}\n  expected: {repr expected}\n  actual:   {repr actual}"

/-- Which tests a run should execute, parsed from the runner's command line. -/
public structure Selection where
  /-- Substring a test name must contain to run. -/
  filter : Option String := none
  /-- Print the selected names and exit without running anything. -/
  list : Bool := false
  /-- `(index, count)`: run only tests whose position in declaration order is congruent to
  `index - 1` modulo `count`. One-based because `--shard 1/3` naming the first third is the
  convention CI matrices already speak. -/
  shard : Option (Nat × Nat) := none

public def Selection.parse : List String → Except String Selection
  | [] => .ok {}
  | "--list" :: rest => do
    let selection ← Selection.parse rest
    .ok { selection with list := true }
  | "--filter" :: pattern :: rest => do
    let selection ← Selection.parse rest
    .ok { selection with filter := some pattern }
  | "--shard" :: spec :: rest => do
    let selection ← Selection.parse rest
    match spec.splitOn "/" with
    | [index, count] =>
      match index.toNat?, count.toNat? with
      | some index, some count =>
        if index == 0 || count == 0 || index > count then
          .error s!"--shard expects 1 ≤ INDEX ≤ COUNT, got: {spec}"
        else
          .ok { selection with shard := some (index, count) }
      | _, _ => .error s!"--shard expects INDEX/COUNT, got: {spec}"
    | _ => .error s!"--shard expects INDEX/COUNT, got: {spec}"
  | argument :: _ => .error s!"unknown argument: {argument}"

/-- The tests `selection` picks out of `cases`, in declaration order. -/
public def Selection.apply (selection : Selection) (cases : Array Case) : Array Case :=
  let filtered := match selection.filter with
    | some pattern => cases.filter (·.name.contains pattern)
    | none => cases
  match selection.shard with
  | some (index, count) => Id.run do
    let mut sharded : Array Case := #[]
    for position in [0:filtered.size] do
      if position % count == index - 1 then
        if let some test := filtered[position]? then
          sharded := sharded.push test
    return sharded
  | none => filtered

/-- Run `cases` under the command line in `args`, printing one line per test and a summary. The
exit code is 1 when any test failed, 2 when the arguments themselves were rejected — the same
convention the product binary uses, so callers can tell a red suite from a misspelled filter. -/
public def runCases (label : String) (cases : Array Case) (args : List String) : IO UInt32 := do
  let selection ← match Selection.parse args with
    | .ok selection => pure selection
    | .error error => do
      IO.eprintln error
      IO.eprintln s!"usage: {label} [--list] [--filter SUBSTRING] [--shard INDEX/COUNT]"
      return 2
  let selected := selection.apply cases
  if selection.list then
    for test in selected do
      IO.println test.name
    return 0
  let mut failures : Array String := #[]
  for test in selected do
    let started ← IO.monoNanosNow
    try
      test.run
      let elapsedMs := ((← IO.monoNanosNow) - started) / 1000000
      IO.println s!"ok   {test.name}  ({elapsedMs}ms)"
    catch error =>
      IO.println s!"FAIL {test.name}\n  {error}"
      failures := failures.push test.name
  if failures.isEmpty then
    IO.println s!"{label}: {selected.size} test(s) passed"
    return 0
  else
    IO.eprintln s!"{label}: {failures.size} of {selected.size} test(s) failed: \
      {", ".intercalate failures.toList}"
    return 1

end LeanFmt.Test
