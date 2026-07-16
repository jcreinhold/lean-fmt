module

public import Lean

open Lean Elab Command

namespace ExactReuseFixtures

public section

meta initialize poisonRef : IO.Ref Bool ← IO.mkRef false

elab "poison_fmt_state" : command =>
  poisonRef.set true

elab "assert_fmt_state_clean" : command => do
  if ← poisonRef.get then
    throwError "formatter reuse leaked process-global command state"

end

end ExactReuseFixtures
