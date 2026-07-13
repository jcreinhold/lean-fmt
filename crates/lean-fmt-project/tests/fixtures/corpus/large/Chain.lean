import Init

/-! A deliberately longer file: a chain of small definitions and theorems, to give the
benchmark corpus a file whose parse/analysis cost is dominated by declaration count rather
than any single large declaration. All content is original. -/

namespace Chain

def step0 (n : Nat) : Nat := n + 1
def step1 (n : Nat) : Nat := step0 n + 1
def step2 (n : Nat) : Nat := step1 n + 1
def step3 (n : Nat) : Nat := step2 n + 1
def step4 (n : Nat) : Nat := step3 n + 1
def step5 (n : Nat) : Nat := step4 n + 1
def step6 (n : Nat) : Nat := step5 n + 1
def step7 (n : Nat) : Nat := step6 n + 1
def step8 (n : Nat) : Nat := step7 n + 1
def step9 (n : Nat) : Nat := step8 n + 1

theorem step0_succ (n : Nat) : step0 n = n + 1 := rfl
theorem step1_succ (n : Nat) : step1 n = n + 2 := rfl
theorem step2_succ (n : Nat) : step2 n = n + 3 := rfl
theorem step3_succ (n : Nat) : step3 n = n + 4 := rfl
theorem step4_succ (n : Nat) : step4 n = n + 5 := rfl

def sumTo : Nat → Nat
  | 0 => 0
  | n + 1 => (n + 1) + sumTo n

theorem sumTo_zero : sumTo 0 = 0 := rfl
theorem sumTo_one : sumTo 1 = 1 := rfl
theorem sumTo_two : sumTo 2 = 3 := rfl

def repeatAdd (base : Nat) : Nat → Nat
  | 0 => base
  | n + 1 => repeatAdd base n + base

theorem repeatAdd_zero (base : Nat) : repeatAdd base 0 = base := rfl

end Chain

namespace ChainProofs

open Chain

theorem chain_monotone (n : Nat) : step0 n ≤ step5 n := by
  simp only [step5, step4, step3, step2, step1, step0]
  omega

theorem sumTo_succ (n : Nat) : sumTo (n + 1) = (n + 1) + sumTo n := rfl

end ChainProofs
