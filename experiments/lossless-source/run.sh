#!/usr/bin/env bash
# Round-trip oracle over the adversarial fixtures for RLS-SPEC.
#
# Each fixture declares its expected outcome, so a change in Lean's parser contract fails loudly
# instead of quietly reclassifying itself:
#
#   accept    the parser accepts the file and the trivia record reconstructs the parsed string
#             byte-for-byte.
#   reject    Lean does not accept these bytes at all, so they are outside "accepted source" and
#             impose no round-trip obligation.
#   truncate  Lean accepts the file, but the trivia record covers only a prefix of it. This is the
#             `#exit` case and is the one class that a lossless projection must handle explicitly.
#
# Tracked fixtures are ordinary module sources. The byte-exotic cases cannot be tracked as `.lean`
# without breaking the repository's native source boundary, so they are generated here from
# explicit bytes.
#
# One process per file: `importModules (loadExts := true)` replays `[init]` code and cannot run
# twice in one process against different module sets.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

work=${1:-$(mktemp -d)}
mkdir -p "$work"

printf 'module\r\n\r\ndef crlf : Nat := 0\r\n' >"$work/Crlf.lean"
printf 'module\n\ndef noFinalNewline : Nat := 0' >"$work/NoFinalNewline.lean"
printf 'module\n\ndef trailingSpace : Nat := 0   \n   \n\n' >"$work/TrailingSpace.lean"
printf 'module\n' >"$work/HeaderOnly.lean"
printf 'module\n\n-- only a comment, no command\n' >"$work/CommentOnly.lean"
printf 'module\n\ndef trailingBlankLines : Nat := 0\n\n\n\n' >"$work/TrailingBlankLines.lean"
# `#exit` is a terminal command: the frontend stops there and never parses the remaining bytes.
printf 'module\n\ndef before : Nat := 0\n#exit\nnot lean at all !!!\n' >"$work/Exit.lean"
# Rejected by the parser: recorded so the boundary of "accepted source" stays evidence, not belief.
printf 'module\n\ndef tabIndent : Nat :=\n\t0\n' >"$work/Tabs.lean"
printf '\xef\xbb\xbfmodule\n\ndef bom : Nat := 0\n' >"$work/Bom.lean"
printf 'module\n\ndef loneCr : Nat := 0\rdef after : Nat := 1\n' >"$work/LoneCr.lean"

lake build round-trip >/dev/null

# fixture:expected
cases=(
  "fixtures/Trivia.lean:accept"
  "fixtures/Tokens.lean:accept"
  "$work/Crlf.lean:accept"
  "$work/NoFinalNewline.lean:accept"
  "$work/TrailingSpace.lean:accept"
  "$work/HeaderOnly.lean:accept"
  "$work/CommentOnly.lean:accept"
  "$work/TrailingBlankLines.lean:accept"
  "$work/Exit.lean:truncate"
  "$work/Tabs.lean:reject"
  "$work/Bom.lean:reject"
  "$work/LoneCr.lean:reject"
)

failures=0
for entry in "${cases[@]}"; do
  file=${entry%:*}
  expected=${entry##*:}
  status=0
  lake exe round-trip "$file" || status=$?
  case $status in
  0) actual=accept ;;
  1) actual=truncate ;;
  3) actual=reject ;;
  *) actual=error ;;
  esac
  if [[ $actual != "$expected" ]]; then
    printf '  UNEXPECTED: %s expected=%s actual=%s (exit %d)\n' \
      "$file" "$expected" "$actual" "$status" >&2
    failures=$((failures + 1))
  fi
done

# `fixtures/Syntax.lean` is the control case and is deliberately not in the table above: it is a
# valid module that a parse-only projection cannot handle, because its own `syntax`/`notation`
# declarations are never elaborated and so never reach the token table. It must be rejected here.
printf '\n--- control: file-local syntax under a parse-only token table ---\n'
status=0
lake exe round-trip fixtures/Syntax.lean || status=$?
if [[ $status -eq 3 ]]; then
  printf '  expected: parse-only projection cannot parse file-local syntax\n'
else
  printf '  UNEXPECTED: parse-only projection did not reject file-local syntax (exit %d)\n' \
    "$status" >&2
  failures=$((failures + 1))
fi

# The same file under the compiler plugin, which does have the file's own token table.
printf '\n--- compiler-plugin probe: same fixtures, elaborated token table ---\n'
lake build ProbeFixtures 2>&1 | grep 'lossless-probe' || {
  printf '  UNEXPECTED: probe produced no report\n' >&2
  failures=$((failures + 1))
}

printf 'cases=%d failures=%d\n' "$((${#cases[@]} + 1))" "$failures"
exit $((failures > 0 ? 1 : 0))
