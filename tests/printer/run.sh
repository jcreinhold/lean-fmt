#!/usr/bin/env bash
set -euo pipefail

# Does the printer's skeleton lose bytes on real parser output?
#
# `RLF-COMMANDS` puts every syntax kind on the conservative path first: a command prints as the bytes
# it was written as until a canonical layout for its kind is cited and pinned. So today
# `Printer.format` is the identity on accepted source, and that is exactly what makes this test worth
# having *now* rather than later. Three places in the skeleton can silently eat a byte — the header
# split at `headerStop`, the command extents tiling `[headerStop, terminalStop)`, and the
# uninterpreted tail from `terminalStop` — and each is checked here against code nobody wrote to suit
# the printer. Every canonical layout that lands later is a change against a skeleton already known to
# be lossless.
#
# `printer-roundtrip` checks the identity at six margins including 0, and checks the extent tiling
# directly rather than inferring it from the bytes: a command dropped whose bytes were absorbed into
# its neighbour's extent would reproduce the source perfectly.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
application=$(lake -q query lean-fmt --text)
tests=$(lake -q query lean-fmt-tests --text)

failures=0
total_commands=0

check_module() {
  local module=$1
  LEAN_NUM_THREADS=1 lake setup-file "$module" >"$work/setup.json"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/setup.json" "$module" "$module" 8589934592 >"$work/envelope.json"
  printf '%-34s ' "$module"
  local report
  if ! report=$("$tests" printer-roundtrip "$work/envelope.json" "$module" 2>&1); then
    printf 'FAIL %s\n' "$report" >&2
    failures=$((failures + 1))
    return
  fi
  printf '%s\n' "$report"
  local commands
  commands=$(printf '%s' "$report" | sed -n 's/.*commands=\([0-9]*\).*/\1/p')
  total_commands=$((total_commands + commands))
}

for module in $(find LeanFmt -name '*.lean' | LC_ALL=C sort) Main.lean; do
  check_module "$module"
done

printf -- '--- corpus ---\n'
printf 'modules_checked=%s commands=%s failures=%s\n' \
  "$(( $(find LeanFmt -name '*.lean' | wc -l | tr -d ' ') + 1 ))" "$total_commands" "$failures"

# A corpus whose modules all projected to zero commands would pass every assertion above while
# testing nothing. A floor rather than an exact count: it rises as the project grows, and only a
# broken walk drives it toward zero.
if [[ "$total_commands" -lt 100 ]]; then
  printf 'FAIL corpus produced only %s commands; the walk is not finding them\n' "$total_commands" >&2
  failures=$((failures + 1))
fi

# The corpus above is this project's own code: no custom syntax, no `#exit`, and almost no non-ASCII.
# Those are exactly the cases the roadmap's stop rules name, so they come from a generated fixture on
# the real parser, with the setup borrowed as `tests/layout/run.sh` borrows one.
printf -- '--- hostile shapes, on the real parser ---\n'
LEAN_NUM_THREADS=1 lake setup-file tests/check/Clean.lean >"$work/borrowed.setup.json"
cat >"$work/hostile.lean" <<'FIXTURE'
module

/-! A module docstring, which is a real token and not trivia. -/

-- A command whose kind this printer has never heard of. `RLF-COMMANDS` stops rather than
-- reformatting it, so it must come back byte-for-byte.
syntax "greet" ident : command
macro_rules | `(greet $x) => `(def $x : Nat := 0)

greet hello

/-- Columns are codepoints (`RLC-SPEC` §4.7), so these under-count their terminal cells by half.
Nothing here may be re-measured, re-indented, or re-wrapped. -/
def unicode : String := "日本語 🎉 café café"

def spanning : String := "a
multi-line literal whose newlines are not the formatter's to touch"

def block : Nat := /- inline -/ 3 /- block comment
spanning a newline -/

#exit
Everything from here is never parsed. It is not a token, it has no kind, and it must survive
verbatim: 日本語 🎉 def this is not real Lean at all /- unterminated
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/hostile.lean" "hostile.lean" 8589934592 \
  >"$work/hostile.json"
if ! hostile=$("$tests" printer-roundtrip "$work/hostile.json" "$work/hostile.lean" 2>&1); then
  printf 'FAIL hostile.lean %s\n' "$hostile" >&2
  failures=$((failures + 1))
else
  printf '%-34s %s\n' "hostile.lean" "$hostile"
  # Exact, because each is a separate claim:
  #   tail_bytes   the `#exit` tail is real and non-empty, so the terminal path is exercised rather
  #                than trivially zero as it is on every module of this repository.
  #   header_bytes the module header is non-empty, so the `[0, headerStop)` split is exercised too.
  tail_bytes=$(printf '%s' "$hostile" | sed -n 's/.*tail_bytes=\([0-9]*\).*/\1/p')
  header_bytes=$(printf '%s' "$hostile" | sed -n 's/.*header_bytes=\([0-9]*\).*/\1/p')
  if [[ "$tail_bytes" -lt 1 ]]; then
    printf 'FAIL the #exit tail is empty; the terminal path was not exercised\n' >&2
    failures=$((failures + 1))
  else
    printf '  ok   the #exit tail round-trips (%s bytes)\n' "$tail_bytes"
  fi
  if [[ "$header_bytes" -lt 1 ]]; then
    printf 'FAIL the module header is empty; the header split was not exercised\n' >&2
    failures=$((failures + 1))
  else
    printf '  ok   the module header round-trips (%s bytes)\n' "$header_bytes"
  fi
fi

# The corpus above cannot test a canonical layout at all: this repository already writes
# `namespace Foo` with one space, so the layout runs and changes nothing, and `printer-roundtrip`
# passing on it says only that the formatter agrees with code already in its own house style. A
# canonical layout is only tested by source that is *not* canonical.
printf -- '--- canonicalization, on source that needs it ---\n'
cat >"$work/wonky.lean" <<'FIXTURE'
module

namespace     Alpha
def a : Nat := 0
end     Alpha

namespace Beta
end Beta

namespace /- a comment between the keyword and the name -/ Gamma
end Gamma
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/wonky.lean" "wonky.lean" 8589934592 >"$work/wonky.json"
"$tests" printer-format "$work/wonky.json" "$work/wonky.lean" 80 >"$work/wonky.out"

# The golden file. Each line of it is a separate claim about the layout:
#   `namespace Alpha` / `end Alpha`  the runs of spaces collapse to exactly one. This is the first
#                                    thing this formatter has ever decided.
#   `def a : Nat := 0`               untouched: `declaration` has no canonical layout yet, so it takes
#                                    the conservative path and keeps its bytes.
#   `namespace Beta` / `end Beta`    already canonical, and stays byte-identical.
#   `namespace /- ... -/ Gamma`      a comment sits between the tokens, so re-spacing would drop it.
#                                    `respaceable` refuses and the command keeps its bytes, comment
#                                    and all. This is the guard, not an accident.
cat >"$work/wonky.golden" <<'GOLDEN'
module

namespace Alpha
def a : Nat := 0
end Alpha

namespace Beta
end Beta

namespace /- a comment between the keyword and the name -/ Gamma
end Gamma
GOLDEN
if diff -u "$work/wonky.golden" "$work/wonky.out" >"$work/wonky.diff" 2>&1; then
  printf '  ok   canonical layout matches the golden file\n'
else
  printf 'FAIL canonical layout does not match the golden file:\n' >&2
  cat "$work/wonky.diff" >&2
  failures=$((failures + 1))
fi

# The layout must actually have *done* something, or the golden file above is just a copy of the
# input and pins nothing.
if diff -q "$work/wonky.lean" "$work/wonky.out" >/dev/null 2>&1; then
  printf 'FAIL the formatter changed nothing; the canonical layout is not being exercised\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   the formatter changed the source (%s)\n' \
    "$(diff "$work/wonky.lean" "$work/wonky.out" | grep -c '^<') lines rewritten"
fi

# Idempotence, the roadmap's "formatting twice is byte-identical to formatting once". The second pass
# re-parses the first pass's *output*, so this is a real second format and not a repeated call: if the
# layout emitted something the parser reads back differently, this is where it shows.
printf -- '--- idempotence ---\n'
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/wonky.out" "wonky.lean" 8589934592 >"$work/wonky2.json"
"$tests" printer-format "$work/wonky2.json" "$work/wonky.out" 80 >"$work/wonky.out2"
if diff -u "$work/wonky.out" "$work/wonky.out2" >"$work/idem.diff" 2>&1; then
  printf '  ok   formatting twice is byte-identical to formatting once\n'
else
  printf 'FAIL formatting is not idempotent:\n' >&2
  cat "$work/idem.diff" >&2
  failures=$((failures + 1))
fi

printf -- '--- result ---\n'
printf 'failures=%s\n' "$failures"
[[ "$failures" -eq 0 ]]
