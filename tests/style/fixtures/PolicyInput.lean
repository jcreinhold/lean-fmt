module

namespace Style

universe   u
variable {α : Type u}

structure Point where
  x:Nat
  y : Nat
  deriving   Repr

inductive Flag where
| off
| on
deriving Repr

syntax "twice!" term : term
macro_rules
| `(twice! $value) => `($value + $value)

def applyTwice (f:α → α) (x : α) : α := f (f x)

def choose (condition : Bool) (yes no : α) : α := if condition then yes else no

def origin : Point := {x:=0,y:=0}

def classify (n : Nat) : Flag := match n with
| 0 => .off
| _ => .on

def optional : Option Nat := do
 let value ← some 1
 pure value

theorem tacticExample : True := by
 constructor

end Style
