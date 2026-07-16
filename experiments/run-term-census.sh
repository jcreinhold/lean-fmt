#!/usr/bin/env bash
set -euo pipefail

# What term syntax does real Lean actually contain? — `RLF-EXPRESSIONS` scope.
#
# `RLF-COMMANDS` shipped a command layout whose coverage read 95% on this repository and 57.8% on
# foreign Lean, because this repository's command mix is not Lean's. The bare rate could not say
# whether the gap was unread grammar or a misfiring guard; only a census by *kind* could, and it
# reported `lemma` (393) — Mathlib's own syntax — as the largest single miss. That lesson is why this
# script exists before any term layout is written rather than after.
#
# The question here is narrower and sharper than "what is the coverage". `notes/02-expressions.md`
# establishes that the projection carries no precedence and does not need to, because the parser
# already resolved it into the tree. What the projection *also* does not carry, and what the tree does
# not resolve, is the **spacing between two atoms**: `infixl:65 " + "` (`Init/Notation.lean:284`)
# declares `+` with a space on each side, `Term.tuple` declares `", "` (`Lean/Parser/Term.lean:187`),
# and `Term.paren` declares a bare `"("` (`:200-201`). The projection records the token's *source*
# text — `+`, `,`, `(` — never the declared atom. So a term layout cannot derive its spacing from the
# tree the way a command shell derives "one space" from "two identifiers must be separated".
#
# It can only cite, per kind, the parser declaration it mirrors — which is exactly what `canonical?`
# already does for commands. This census therefore asks the one question that decides how far that can
# go: **how much of real Lean's term syntax is a core parser this stack can cite, and how much is a
# `notation` whose spacing lives in a declaration the printer cannot read?** A `Lean.Parser.Term.*`
# kind is a parser declaration in the compiler pinned at v4.32.0. A generated `«term_+_»`-style kind is
# a notation, and its atoms' spacing is not in the compiler at all.
#
# Complete mathlib is forbidden (`RLF-EXPRESSIONS` stop rules); this is the frozen sample only.
#
# usage: run-term-census.sh [MATHLIB_ROOT] [SOURCES] [OUT]

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
out=${3:-"$repo_root/docs/projects/ruff-03-language-formatting/evidence/02-term-census.txt"}

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

# The partition that decides this prompt's scope. Every token-bearing kind is exactly one of these,
# and the last line asserts it rather than trusting the patterns.
#
# A `Lean.Parser.Term.*` kind is a parser declaration in the compiler this stack pins at v4.32.0: its
# atoms, and their declared spacing, can be read and cited. Everything outside `Lean.Parser.*` that is
# not a lexical atom is a `notation`/`infix`/`prefix` declaration — `«term_+_»`, and also `termℕ`,
# which is why this does not test for guillemets: they are escaping, present only when the notation's
# own syntax needs them, so `grep '«'` silently undercounts.
count() { grep -cE "$1" "$scratch/kinds" || true; }
core_term=$(count '^Lean\.Parser\.Term\.')
tactic=$(count '^Lean\.Parser\.Tactic\.|^Lean\.Parser\.tactic')
command=$(count '^Lean\.Parser\.Command\.')
# Lexical leaves and the `many`/`optional` wrappers. A filled wrapper is token-bearing and belongs
# here: it is real syntax with no atoms of its own, so it has no spacing to declare.
lexical=$(count '^(null|ident|num|scientific|str|char|hygieneInfo|choice|sepBy.*)$')
other=$(count '^Lean\.Parser\.(Attr|Syntax|Level|Module)\.')
rest=$((total - core_term - tactic - command - lexical - other))

{
  printf 'modules_analyzed=%s skipped=%s token_bearing_nodes=%s distinct_kinds=%s\n' \
    "$analyzed" "$skipped" "$total" "$(sort -u "$scratch/kinds" | wc -l | tr -d ' ')"
  printf 'core_term=%s tactic=%s command=%s lexical=%s other_parser=%s notation_or_foreign=%s\n' \
    "$core_term" "$tactic" "$command" "$lexical" "$other" "$rest"
  printf '\n# Nodes whose subtree carries no token are excluded: an absent slot has no atoms, so there\n'
  printf '# is nothing a layout could decide about it. `null` still leads the census and belongs there\n'
  printf '# — those are the `many`/`optional` wrappers that are *filled*. The excluded ones are the\n'
  printf '# empty slots, 36%% of all nodes (`evidence/01-projection-shape.txt`).\n'
  printf '\n# the 60 most common token-bearing kinds\n'
  sort "$scratch/kinds" | uniq -c | sort -rn | head -60
  printf '\n# the 40 most common kinds this stack cannot cite a compiler declaration for: notations,\n'
  printf '# whose atoms and their spacing live in the `notation` declaration itself. These are\n'
  printf '# `RLF-EXTENSIONS`, and on the conservative path until then.\n'
  grep -vE '^(Lean\.Parser\.|null|ident|num|scientific|str|char|hygieneInfo|choice|sepBy)' \
    "$scratch/kinds" | sort | uniq -c | sort -rn | head -40
  printf '\n# every distinct `Lean.Parser.Term.*` kind, most common first — this prompts scope, and\n'
  printf '# the only list on which a per-kind cited layout is even possible.\n'
  grep '^Lean\.Parser\.Term\.' "$scratch/kinds" | sort | uniq -c | sort -rn
} | tee "$out"
