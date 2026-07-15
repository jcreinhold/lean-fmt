import Init

/-- A point in the discrete plane. -/
structure Point where
  x : Nat
  y : Nat

namespace Point

def origin : Point := { x := 0, y := 0 }

def shiftX (p : Point) (dx : Nat) : Point := { p with x := p.x + dx }

def manhattan (p : Point) : Nat := p.x + p.y

theorem manhattan_origin : manhattan origin = 0 := rfl

theorem shiftX_manhattan (p : Point) (dx : Nat) : manhattan (shiftX p dx) = manhattan p + dx := by
  simp [manhattan, shiftX, Nat.add_right_comm]

end Point

inductive Tree where
  | leaf : Nat → Tree
  | node : Tree → Tree → Tree

def Tree.size : Tree → Nat
  | .leaf _ => 1
  | .node l r => l.size + r.size
