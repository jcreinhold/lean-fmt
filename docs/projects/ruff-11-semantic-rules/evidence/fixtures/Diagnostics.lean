-- Characterization fixture for RMR-SPEC. Each declaration triggers exactly one
-- default-on Lean 4.32.0 linter with a stable `kind` tag and an exact range.

def newName : Nat := 1

-- FMT014: deprecated declaration use  (kind: Lean.Linter.deprecatedAttr)
@[deprecated newName (since := "2024-01-01")]
def oldName : Nat := 0
def useOld : Nat := oldName

-- FMT015: unused variable / binder    (kind: linter.unusedVariables)
def hasUnused (x : Nat) : Nat := 5

-- FMT016: unused section variable      (kind: linter.unusedSectionVars)
section
variable {α : Type} [inst : Inhabited α]
theorem usesAlphaNotInst (a : α) : a = a := rfl
end

-- FMT017: bound var resembles a nullary constructor (kind: linter.constructorNameAsVariable)
def shadows (true : Bool) : Bool := true
