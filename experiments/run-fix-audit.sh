#!/usr/bin/env bash
# RGR-EVIDENCE §3 fix audit (`ruff-12b`). Exercises every fixable rule under judgement — FMT008,
# FMT009, FMT011 (syntax) and FMT012 (semantic) — against `results/01-criteria.md` §3.
#
# `tests/syntax/run.sh`'s `fix_applies` already covers FX-3 (convergence: a re-`check` of the written
# file reports nothing) for FMT008/011/013. It does NOT cover:
#
#   FX-2  true byte idempotence — `fix` twice equals `fix` once, compared with `cmp`. The existing
#         test infers this from "the re-check found nothing", which assumes no findings implies no
#         write. That is very likely true and is exactly the kind of assumption a fix audit should
#         stop assuming.
#   FX-4  the fixed file still parses and elaborates under the exact module setup.
#
# and it does not cover FMT012 at all (that fix is `.unsafe` and lives in `tests/semantic/run.sh`).
#
# This harness closes those gaps. It is an audit, not a suite: it prints a table and exits non-zero
# only if an assertion it makes actually fails.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
fmt="$repo_root/.lake/build/bin/lean-fmt"
[[ -x $fmt ]] || { echo "build lean-fmt first" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# One case: apply `fix` twice to a copy of `fixture` under `selector`, and check FX-2, FX-3, FX-4.
audit() {
  local label=$1 fixture=$2 selector=$3; shift 3
  local extra=("$@")
  local probe="tests/syntax/.rgr-audit-$label.lean"
  cp "$fixture" "$probe"

  "$fmt" fix --root . --json --no-cache --preview --select "$selector" ${extra[@]+"${extra[@]}"} "$probe" \
    >"$work/$label.fix1.json" 2>/dev/null || true
  cp "$probe" "$work/$label.once"

  "$fmt" fix --root . --json --no-cache --preview --select "$selector" ${extra[@]+"${extra[@]}"} "$probe" \
    >"$work/$label.fix2.json" 2>/dev/null || true
  cp "$probe" "$work/$label.twice"

  # FX-2. Byte identity between one application and two.
  local fx2=ok
  cmp -s "$work/$label.once" "$work/$label.twice" || { fx2=FAIL; failures=$((failures + 1)); }

  # FX-3. One pass converges: no finding of that rule survives.
  local remaining fx3=ok
  "$fmt" check --root . --json --no-cache --preview --select "$selector" ${extra[@]+"${extra[@]}"} "$probe" \
    >"$work/$label.recheck.json" 2>/dev/null || true
  remaining=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["findings"])' \
    "$work/$label.recheck.json" 2>/dev/null || echo '?')
  [[ $remaining == 0 ]] || { fx3=FAIL; failures=$((failures + 1)); }

  # FX-4. The fixed bytes still parse and elaborate. `check` over the written file goes through the
  # exact module setup, so an `infrastructureFailures` entry or a `broken` count is the signal; a
  # file that no longer elaborates cannot report zero findings cleanly.
  local fx4=ok broken infra
  broken=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["broken"])' \
    "$work/$label.recheck.json" 2>/dev/null || echo '?')
  infra=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["infrastructureFailures"]))' \
    "$work/$label.recheck.json" 2>/dev/null || echo '?')
  [[ $broken == 0 && $infra == 0 ]] || { fx4=FAIL; failures=$((failures + 1)); }

  local wrote1 wrote2
  wrote1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["written"])' \
    "$work/$label.fix1.json" 2>/dev/null || echo '?')
  wrote2=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["written"])' \
    "$work/$label.fix2.json" 2>/dev/null || echo '?')

  printf '%-28s wrote=%s/%s  FX-2 idempotent=%-4s  FX-3 converged=%-4s  FX-4 elaborates=%-4s\n' \
    "$label ($selector)" "$wrote1" "$wrote2" "$fx2" "$fx3" "$fx4"
  rm -f "$probe"
}

printf 'RGR-EVIDENCE §3 fix audit — FX-2 (byte idempotence), FX-3 (convergence), FX-4 (elaborates)\n'
printf 'wrote=N/M is files written by the first / second `fix`; M must be 0 for a converged fix.\n\n'

printf -- '--- fixtures ---\n'
audit fmt013-nested   tests/syntax/NestedParen.lean       FMT011
audit fmt013-triple   tests/syntax/NestedParenTriple.lean FMT011
audit fmt013-utf8     tests/syntax/NestedParenUtf8.lean   FMT011
audit fmt013-comment  tests/syntax/Comment.lean           FMT011
audit fmt010-dup      tests/syntax/Duplicates.lean        FMT008
audit fmt011-dup      tests/syntax/Duplicates.lean        FMT009
audit fmt010-quote    tests/syntax/QuoteAttr.lean         FMT008
audit fmt013-quote    tests/syntax/QuoteParen.lean        FMT011
audit fmt013-attr     tests/syntax/AttrThenParen.lean     FMT011

printf -- '\n--- FX-6 composition: the three safe fixes selected together ---\n'
audit compose-all     tests/syntax/Duplicates.lean        FMT008 --select FMT009 --select FMT011

printf '\n'
if ((failures)); then
  printf 'fix audit: %d assertion(s) FAILED\n' "$failures" >&2
  exit 1
fi
printf 'fix audit: ok (no assertion failed)\n'
