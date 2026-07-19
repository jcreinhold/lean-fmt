module

/-! Adversarial fixture for the FMT014 fixable-occurrence predicate (`ruff-11b` ROS-FINAL). Each
deprecated declaration carries a `newName?` replacement; the uses below exercise the predicate's
boundary: a bare identifier (fixable), and non-bare spellings — namespace-qualified, `open`-shadowed,
dot-projection — that a textual single-token rename must NOT claim, plus a `newName? = none` entry that
stays report-only. Every use is a **warning**, so the module elaborates and `analyzeExact` captures. -/

def newBare : Nat := 1
@[deprecated newBare (since := "2024-01-01")]
def oldBare : Nat := 0

namespace N
def newNs : Nat := 3
@[deprecated newNs (since := "2024-01-01")]
def oldNs : Nat := 2
end N

@[deprecated (since := "2024-01-01")]
def oldNoRepl : Nat := 4

structure Wrap where
  val : Nat
def Wrap.newGet (w : Wrap) : Nat := w.val
@[deprecated Wrap.newGet (since := "2024-01-01")]
def Wrap.oldGet (w : Wrap) : Nat := w.val

-- Bare identifier: the whole occurrence token spells `oldBare`, renaming to `newBare` is exact.
def useBare : Nat := oldBare

-- Namespace-qualified: the occurrence spells `N.oldNs` (a dotted name, not a bare identifier).
def useQualified : Nat := N.oldNs

-- `open`-shadowed: the occurrence spells the bare `oldNs` but resolves to `N.oldNs`, whose replacement
-- `N.newNs` is not reachable under this spelling.
def useOpened : Nat := open N in oldNs

-- Deprecation with no replacement name: nothing to substitute.
def useNoRepl : Nat := oldNoRepl

-- Dot-notation projection: the occurrence spells the bare `oldGet` after the dot, resolving to
-- `Wrap.oldGet`. Replacing the projection head would break the `w.___` syntax.
def useDot (w : Wrap) : Nat := w.oldGet
