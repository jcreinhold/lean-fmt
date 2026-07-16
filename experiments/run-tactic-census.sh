#!/usr/bin/env bash
set -euo pipefail

# What tactic syntax does real Lean actually contain? — `RLF-TACTICS` scope.
#
# `run-term-census.sh` answered `RLF-EXPRESSIONS`'s scope question — how much of real Lean's *term*
# syntax is a core parser this stack can cite — and its exhaustive list is deliberately
# `Lean.Parser.Term.*` only (`evidence/02-term-census.txt`, last section). Tactic kinds appear there
# only in the top-60, which is enough to see that `tacticSeq` is 1967 and `tacticSeq1Indented` is 1966
# and not enough to conclude anything: `tacticSeqBracketed` is below the cut, and the difference of the
# two is *not* its count, because `tacticSeqIndentGt`'s `pushNone` branch (`Term/Basic.lean:90-92`)
# makes token-free `tacticSeq1Indented` nodes that a token-bearing census excludes by construction.
# Inferring `1967 - 1966 = 1` is exactly the arithmetic that produced the stale `7` this stack had to
# correct in `results/02-expressions.md`. Hence a census rather than a subtraction.
#
# The question this one asks is different from the term census's, because the answer to "can this be
# cited" is already yes. `notes/03-tactics.md` §2-3 reads the grammar: what this script counts —
# tactic sequences and their bracketed spelling — is `sepBy1Indent` (`Lean/Parser/Extra.lean:202-208`),
# in the pinned compiler and citable. (§3 names a second family, `many1Indent` (`:190-191`), which has
# no separator clause at all; `do` and match alternatives are that one. Neither is counted here, and
# neither is `RLF-TACTICS`'s to lay out.) What is *not* known is how much of it this printer may touch, and §5
# says that turns on a property no kind census can see — whether the printer owns every newline inside
# a block. So this script answers the two questions that are countable by kind:
#
#   1. **Is the bracketed form worth a layout at all?** `{ tacs }` is an alternative spelling
#      (`Term/Basic.lean:76-79`) whose braces are declared `"{ "` and `"}"` — spaced open, bare close,
#      which is `structInst`'s trap again (`notes/02-expressions.md` §5b) and needs its own reading, not
#      a family rule. If real Lean never writes it, that reading is dead code.
#   2. **How concentrated are the tactic kinds?** A layout that must cite each kind it touches is
#      bounded by how many kinds carry the mass.
#
# The line-span question §6 raises — how many blocks have every gap on one line — is *not* here. It is
# not a property of a kind, so no census can report it; it needs a counter in the printer, the way
# `app_slack` did.
#
# Complete mathlib is forbidden (`RLF-TACTICS` stop rules); this is the frozen sample only.
#
# usage: run-tactic-census.sh [MATHLIB_ROOT] [SOURCES] [OUT]

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
out=${3:-"$repo_root/docs/projects/ruff-03-language-formatting/evidence/03-tactic-census.txt"}

application="$repo_root/.lake/build/bin/lean-fmt"
tests="$repo_root/.lake/build/bin/lean-fmt-tests"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

for binary in "$application" "$tests"; do
  if [[ ! -x "$binary" ]]; then
    printf 'missing %s; run `LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests` first\n' \
      "$binary" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$out")"
: >"$scratch/kinds"
analyzed=0
skipped=0

cd "$mathlib_root"
while read -r source; do
  [[ -n "$source" ]] || continue
  setup="$scratch/setup.json"

  if ! LEAN_NUM_THREADS=1 lake setup-file "$source" >"$setup" 2>"$scratch/err"; then
    skipped=$((skipped + 1))
    continue
  fi
  if ! LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
      "$setup" "$source" "$source" 8589934592 >"$scratch/env.json" 2>"$scratch/err"; then
    skipped=$((skipped + 1))
    continue
  fi
  if ! "$tests" printer-node-kinds "$scratch/env.json" "$source" >>"$scratch/kinds" \
      2>"$scratch/err"; then
    skipped=$((skipped + 1))
    continue
  fi
  analyzed=$((analyzed + 1))
done <"$sources"

total=$(wc -l <"$scratch/kinds" | tr -d ' ')

count() { grep -cE "$1" "$scratch/kinds" || true; }
# The `sepByIndent` family from `notes/03-tactics.md` §3 — the constructs whose separator is a
# linebreak at the saved column. `Lean.cdot` is the tactic bullet (`Init/NotationExtra.lean:320-322`);
# `Lean.Parser.Term.cdot` is the unrelated function abbreviation `(· + 1)` and is deliberately not
# matched here.
tactic=$(count '^Lean\.Parser\.Tactic\.|^Lean\.Parser\.tactic')
seq_all=$(count '^Lean\.Parser\.Tactic\.tacticSeq$')
seq_indented=$(count '^Lean\.Parser\.Tactic\.tacticSeq1Indented$')
seq_bracketed=$(count '^Lean\.Parser\.Tactic\.tacticSeqBracketed$')
bullet=$(count '^Lean\.cdot$')

{
  printf 'modules_analyzed=%s skipped=%s token_bearing_nodes=%s\n' "$analyzed" "$skipped" "$total"
  printf 'tactic_nodes=%s tacticSeq=%s tacticSeq1Indented=%s tacticSeqBracketed=%s bullets=%s\n' \
    "$tactic" "$seq_all" "$seq_indented" "$seq_bracketed" "$bullet"
  printf '\n# `tacticSeqBracketed` is the number this census exists for. `tacticSeq` minus\n'
  printf '# `tacticSeq1Indented` does NOT equal it: `tacticSeqIndentGt` falls back to\n'
  printf '# `node ``tacticSeq1Indented pushNone` (`Term/Basic.lean:90-92`), which carries no token and\n'
  printf '# is excluded from this census the way every empty slot is. Only the direct count is honest.\n'
  printf '\n# Nodes whose subtree carries no token are excluded, as in the term census: an absent slot\n'
  printf '# has no atoms, so there is nothing a layout could decide about it.\n'
  printf '\n# every distinct tactic kind this stack can cite a compiler declaration for, most common\n'
  printf '# first. `Lean.Parser.Tactic.*` is a parser declaration in the compiler pinned at v4.32.0;\n'
  printf '# its atoms and their declared spacing can be read. This is the only list on which a per-kind\n'
  printf '# cited tactic layout is even possible.\n'
  grep -E '^Lean\.Parser\.Tactic\.' "$scratch/kinds" | sort | uniq -c | sort -rn

  printf '\n# every distinct tactic-position kind this stack CANNOT cite: `Mathlib.Tactic.*` and other\n'
  printf '# corpus-defined `syntax`/`macro` declarations. These are an open set — the corpus being\n'
  printf '# formatted extends it — and the same closed-versus-open test that licensed the binders\n'
  printf '# (`notes/02-expressions.md` §5) refuses them.\n'
  grep -vE '^(Lean\.Parser\.|Lean\.cdot|null|ident|num|scientific|str|char|hygieneInfo|choice|sepBy)' \
    "$scratch/kinds" | grep -iE 'tactic|tac' | sort | uniq -c | sort -rn | head -40
} >"$out"

printf 'wrote %s\n' "$out"
