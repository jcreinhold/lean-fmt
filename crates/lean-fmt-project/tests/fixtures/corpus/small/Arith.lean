import Init

def add3 (a b c : Nat) : Nat := a + b + c

def square (n : Nat) : Nat := n * n

example : add3 1 2 3 = 6 := rfl
