module

/-! A **`module`-mode** fixture — the case the first RSF-IMPL missed. In module mode the module system
strips imported constants' kernel values (`ConstantInfo.value?`), so the original `value?` capture
returned *nothing* here for the imported `+`/`*` operators (60/62 of the frozen sample and 8194/8264
of `Mathlib/` are module-mode). The reopened capture reads the descriptor through the compiled meta IR
(`evalConst Lean.ParserDescr`), which the module system retains, so it must recover `" + "`/`" * "`
here all the same. The harness asserts exactly that — a non-empty capture for the imported operators —
which fails on the old path and passes on the new. -/

/-- A corpus-declared notation: a breakable gap on both sides of a symbolic atom. The production
capture path must recover its untrimmed `" ⊕corpus "`, just as it recovers core `+`/`*`. -/
notation:65 a " ⊕corpus " b => HAdd.hAdd a b

def usesCorpus (a b : Nat) : Nat := a ⊕corpus b

def usesCore (a b : Nat) : Nat := a + b * a
