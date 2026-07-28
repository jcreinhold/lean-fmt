module

namespace BlockFixture

syntax "custom_assumption" : tactic
local notation "customNat" => (1 : Nat)

macro_rules
  | `(tactic| custom_assumption) => `(tactic| assumption)

theorem atomic (proposition : Prop) (proof : proposition) : proposition := by exact proof

theorem sequence (left right : Prop) (leftProof : left) (rightProof : right) : left ∧ right := by
  constructor
  · exact leftProof
  · exact rightProof

theorem alternatives (proposition : Prop) (proof : proposition) : proposition := by
  first
  | exact proof
  | assumption

theorem combinator : True ∧ True := by
  constructor <;> trivial

theorem custom (proposition : Prop) (proof : proposition) : proposition := by
  custom_assumption

theorem commented : True ∧ True := by
  constructor
  /- between focused goals -/
  · trivial
  · trivial

def matchBlock (value : Nat) : Nat :=
  match value with
  | 0 => by exact 1
  | _ => by
    exact value

def doBlock : Option Nat := do
  let first ← some 1
  let second := first + 1
  pure second

def letFallback (input : Option Nat) : Option Nat := do
  let some value := input | return 0
  pure value

def bindFallback (input : Option (Option Nat)) : Option Nat := do
  let some value ← input | return 0
  pure value

def longLetFallback (input : Option Nat) : Option Nat := do
  /- long guarded let -/
  let some value := input | return Array.replicate 12 0 |>.size
  pure value

def longBindFallback (input : Option (Option Nat)) : Option Nat := do
  /- long guarded bind -/
  let some value ← input | return Array.replicate 12 0 |>.size
  pure value

def mutableLoop (values : Array Nat) : Nat := Id.run do
  let mut total := customNat
  total ← pure (total + 1)
  have positive : 0 < total + 1 := Nat.zero_lt_succ total
  for value in values do
    if value == 0 then
      continue
    total := total + value
    if total > 100 then
      break
  while total < 10 do
    total := total + 1
  return total

def recursiveItem : Option Nat := do
  let rec count : Nat → Nat
    | 0 => 0
    | value + 1 => count value + 1
  pure (count 3)

def conditional (value : Option Nat) : Option Nat := do
  if let some current := value then
    pure current
  else if value.isNone then
    pure 0
  else
    pure 1

def guarded (flag : Bool) : Option Nat := do
  unless flag do
    return 0
  repeat
    return 1
  until flag
  pure 2

def nestedAction : Option Nat := do
  let value ← do
    let inner := 1
    pure inner
  pure value

def bracketedAction : Option Nat := do { let value := 1; pure value }

def matchedAction (value : Option Nat) : Option Nat := do
  match value with
  | some current =>
    /- match-arm comment -/
    pure current
  | none =>
    pure 0

def exceptionAction : IO Nat := do
  try
    pure 1
  catch _ =>
    pure 2
  finally
    pure ()

def exceptionMatchAction : IO Nat := do
  try
    pure 1
  catch
  | _ => pure 2

def diagnosticItems (flag : Bool) : IO Unit := do
  dbg_trace s!"flag: {flag}"
  assert! flag || !flag
  debug_assert! flag || !flag
  return

def idRunBlock : Nat := Id.run do
  let first := 1
  let second := first + 1
  pure second

def localDeclaration (value : Nat) : Nat := helper value
where
  helper (current : Nat) : Nat := current + 1

end BlockFixture
