module

def bar : Nat := 1

@[deprecated bar (since := "1.0")]
def foo : Nat := 0

-- First use of the deprecated `foo`, in a later command.
def usesFooA : Nat := foo

-- A still-later command referencing `foo` again, to prove multi-command reachability:
-- the occurrence must appear in a *different* command's info tree than `usesFooA`.
def usesFooB : Nat := foo + bar

-- A non-deprecated reference, to prove the fold does not over-report.
def usesBar : Nat := bar
