#!/usr/bin/env bash
set -euo pipefail

# Attribution run for the six pinned layout defects. Prints Lean's own native document for one
# minimized reproduction of each, so a defect can be assigned to the upstream formatter or to the
# adapter. See README.md for the measured result; this regenerates it.
#
# D1, D3, and D6 are about comments, and the adapter strips trivia before native formatting, so no
# native document here can contain one. They are included anyway: the absence is the evidence.

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
cd "$repo"

widths=${LEAN_FMT_DEFECT_WIDTHS:-100}

probe() {
  local label=$1 width=$2
  printf '########## %s (width=%s)\n' "$label" "$width"
  lake env lean --run "$here/Probe.lean" "$width"
}

probe "D2 constructor docstring" "$widths" <<'EOF'
module

inductive Choice where
  /-- A constructor doc comment stays on its constructor. -/
  | left
  | right
EOF

# The same shape with a docstring that runs onto a second line. The document is identical apart from
# the docstring leaf, which is what makes it interesting: the adapter protects that leaf as an exact
# island whose bytes carry absolute source columns, so D2's constraint and the island's own cancelling
# `nest` are two indentation decisions over the same range. See the README.
probe "D2 constructor docstring, spanning two lines" "$widths" <<'EOF'
module

inductive Spanning where
  /-- A constructor doc comment that runs onto a second line
  keeps both of its lines. -/
  | only
EOF

probe "D4 guarded let" "$widths" <<'EOF'
module

def guardedSibling (value : Option Nat) : Nat := Id.run do
  let some current := value | return 0
  let doubled := current + current
  return doubled + 1
EOF

probe "D5 by on the := line" "$widths" <<'EOF'
module

theorem tacticSiblings (n : Nat) : n + 0 = n := by
  have step : n + 0 = n := Nat.add_zero n
  exact step
EOF

# The D5 threshold. Nothing about it is a property of the line being laid out, which is the finding.
printf '########## D5 threshold sweep\n'
for width in 100 135 136 400; do
  line=$(
    probe "D5" "$width" <<'EOF' 2>/dev/null | sed -n '/--- native ---/{n;p;}'
module

theorem tacticSiblings (n : Nat) : n + 0 = n := by
  have step : n + 0 = n := Nat.add_zero n
  exact step
EOF
  )
  printf 'width=%-4s [%s]\n' "$width" "$line"
done

# The controls. Each of these is *correct* today, and a repair for D5 must leave all four alone.
# `fun` and bare `do` show `ppAllowUngrouped` working; `by rfl` shows the same `by` staying on the line
# when its tactic sequence is one line; `Id.run do` shows the `declValSimple` hard line that applies
# because the body's head is an application, not `do`.
probe "control: fun" "$widths" <<'EOF'
module

def viaFun : Nat → Nat := fun value =>
  value + 1
EOF

probe "control: bare do" "$widths" <<'EOF'
module

def viaDoDirect : Id Nat := do
  return 1
EOF

probe "control: single-tactic by" "$widths" <<'EOF'
module

theorem shortBy (n : Nat) : n = n := by
  rfl
EOF

probe "control: Id.run do, the declValSimple hard line" "$widths" <<'EOF'
module

def viaDo (value : Nat) : Nat := Id.run do
  return value + 1
EOF

# D7, found after the six above were repaired. `pushToken` (`Lean/PrettyPrinter/Formatter.lean:383-407`)
# decides the discretionary space between two adjacent tokens by re-lexing alone. Both loops below are
# the same syntax; only the token before `do` differs. `list` then `do` re-lexes as one identifier, so
# the document holds a space; `]` then `do` does not, so it holds nothing.
probe "D7 space before do" "$widths" <<'EOF'
module

def loops (list : List Nat) : Nat := Id.run do
  let mut total := 0
  for value in list do
    total := total + value
  for value in #[1, 2, 3] do
    total := total + value
  return total
EOF
