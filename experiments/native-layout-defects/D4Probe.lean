module

def longLetFallback (input : Option Nat) : Option Nat := do
  /- long guarded let -/
  let some value := input | return Array.replicate 12 0 |>.size
  pure value
