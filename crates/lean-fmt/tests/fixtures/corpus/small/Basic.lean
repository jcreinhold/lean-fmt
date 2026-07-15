import Init

def double (n : Nat) : Nat := n + n

theorem double_zero : double 0 = 0 := rfl
