#!/usr/bin/env bash
set -euo pipefail

# Live-syntax comment ownership over real parsed modules.
#
# The exact frontend retains actual header, command, choice-selected, and terminal syntax while it
# builds the summary. This drives that path over the repository's changing production corpus.
#
# The claim under test is the roadmap's "preserve every comment exactly once". It is decidable rather
# than aspirational: the live-syntax summary validates one owner per independently extracted payload.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
application=$(lake -q query lean-fmt --text)
tests=$(lake -q query lean-fmt-tests --text)

failures=0
total_comments=0
total_dangling=0

printf -- '--- layout document properties ---\n'
if "$tests" doc-properties; then
  printf '  ok   widths 0/1/40/80/100/1000, Unicode, groups, marks, and registered leaves\n'
else
  printf 'FAIL layout document properties\n' >&2
  failures=$((failures + 1))
fi

check_module() {
  local module=$1
  LEAN_NUM_THREADS=1 lake setup-file "$module" >"$work/setup.json"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/setup.json" "$module" "$module" 8589934592 3 >"$work/envelope.json"
  printf '%-34s ' "$module"
  local report
  if ! report=$("$tests" comment-summary "$work/envelope.json" 2>&1); then
    printf 'FAIL %s\n' "$report" >&2
    failures=$((failures + 1))
    return
  fi
  printf '%s\n' "$report"
  local comments dangling
  comments=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["comments"])' <<<"$report")
  dangling=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["dangling"])' <<<"$report")
  total_comments=$((total_comments + comments))
  total_dangling=$((total_dangling + dangling))
}

# Largest last, so a regression surfaces on a small module first.
for module in $(find LeanFmt -name '*.lean' | LC_ALL=C sort) Main.lean; do
  check_module "$module"
done

printf -- '--- corpus ---\n'
printf 'modules_checked=%s comments_owned=%s dangling=%s failures=%s\n' \
  "$(find LeanFmt -name '*.lean' | wc -l | tr -d ' ')" "$total_comments" "$total_dangling" "$failures"

# A corpus that owned no comment would pass every assertion above while testing nothing. A floor
# rather than an exact count: the number rises as the project is commented, and only a broken walk
# drives it toward zero.
if [[ $total_comments -lt 25 ]]; then
  printf 'FAIL corpus owned only %s comments; the walk is not finding them\n' "$total_comments" >&2
  failures=$((failures + 1))
fi

# Every module above reports `trailing=0`: this repository puts its comments on their own lines, so
# the corpus never exercises the split at all. A real parser is needed for the other positions, and a
# fixture is the only way to get them — so the setup is borrowed exactly as `tests/lossless/run.sh`
# borrows one, and the source is generated.
printf -- '--- comment positions, on the real parser ---\n'
LEAN_NUM_THREADS=1 lake setup-file tests/check/Clean.lean >"$work/borrowed.setup.json"
cat >"$work/positions.lean" <<'FIXTURE'
module

def a : Nat := 0  -- trailing, same line as the token

-- leading, own line, before a declaration
def b : Nat := 1

def c : Nat := /- inline block -/ 2

def d : Nat := 3 /- block comment
spanning a newline -/

-- dangling: past the last token, owned by no one
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/positions.lean" "positions.lean" 8589934592 \
  3 >"$work/positions.json"
positions=$("$tests" comment-summary "$work/positions.json")
printf '%-34s %s\n' "positions.lean" "$positions"

# Exact, because each number is a separate claim about the rule:
#   trailing=3  `-- trailing`, `/- inline block -/`, and the newline-spanning block comment. The last
#               is the case Lean's own `chooseNiceTrailStop` would tear in half, and the inline block
#               is the "dangling" case an AST formatter needs a category for.
#   leading=1   `-- leading` is past the first newline, so it leads the next token rather than
#               trailing the previous one — the whole point of the split.
#   dangling=1  nothing follows the last token to lead.
expect() {
  local label=$1 expected=$2
  if [[ $positions != *"$expected"* ]]; then
    printf 'FAIL %s: expected %s in: %s\n' "$label" "$expected" "$positions" >&2
    failures=$((failures + 1))
  else
    printf '  ok   %s\n' "$label"
  fi
}
expect "every comment owned exactly once" '"comments":5'
expect "same-line comments trail their syntax leaf" '"trailing":3'
expect "an own-line comment leads the next syntax leaf" '"leading":1'
expect "a comment past the last token is file-dangling" '"dangling":1'

printf 'failures=%d\n' "$failures"
exit $((failures > 0 ? 1 : 0))
