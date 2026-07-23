module

namespace NativeLayoutRouteFixture

def add (alpha : Nat) (beta : Nat) : Nat := alpha+beta

def guarded (value : Option Nat) : Nat := Id.run do
  let some current := value | return 0
  return current + 1

def layoutRecord : Prod Nat Nat where
  fst := 1
  snd := 2

def nested (value : Nat) : Nat :=
  match value with
  | 0 => 1
  | n + 1 =>
    if n = 0 then 2
    else n + 3

def commented (alpha beta : Nat) : Nat :=
  alpha + -- keep this payload exactly
    beta

end NativeLayoutRouteFixture
