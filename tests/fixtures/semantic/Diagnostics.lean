module

/-! A `module`-mode fixture whose declarations each trigger exactly one default-on Lean 4.32.0 linter
with a stable `kind` tag and an exact range — the compiler diagnostics' semantic rules
FMT012–FMT015 surface. Every diagnostic here is a **warning**, so the module elaborates and
`analyzeExact` produces an artifact (it returns `broken` only on errors); the semantic suite asserts
the captured `diagnostics` reproduce the compiler's own `kind`s and ranges. -/

def newName : Nat := 1

-- FMT012: deprecated declaration use  (kind: Lean.Linter.deprecatedAttr)
@[deprecated newName (since := "2024-01-01")]
def oldName : Nat := 0
def useOld : Nat := oldName

-- FMT013: unused variable / binder    (kind: linter.unusedVariables)
def hasUnused (x : Nat) : Nat := 5

-- FMT014: unused section variable      (kind: linter.unusedSectionVars)
section
variable {α : Type} [inst : Inhabited α]
theorem usesAlphaNotInst (a : α) : a = a := rfl
end

-- FMT015: bound var resembles a nullary constructor (kind: linter.constructorNameAsVariable)
def shadows (true : Bool) : Bool := true
