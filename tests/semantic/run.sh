#!/usr/bin/env bash
set -euo pipefail

# RSF-FINAL acceptance for the semantic notation-spacing fact (ruff-05b). Proves, on the real
# production capture path (`__analyze-exact`, the on-demand `analyzeExact` producer), that:
#   A. the fresh-frontend differential holds for core *and* a corpus-declared notation — the captured
#      declared spacing equals what Lean's own `ppTerm`/`pushToken` emits, computed independently;
#   A'. the differential is non-vacuous — a deliberately wrong atom does not match the emission;
#   B. demand-gating runs both directions — `captureSemantic=0` yields `semantic = null` with a source
#      projection byte-identical to the capturing run, and end to end a `format` run rejects the
#      plugin's `semantic = none` artifact while `check` serves source-tier from it;
#   C. the v4 artifact is byte-stable across runs (a stable cache digest).
# The in-module `run_cmd` differential in `LeanFmtTest.lean` covers the corpus case against `ppTerm`
# directly; this harness adds what the module system hides in-module — core notation *values* are
# only visible in the live frontend env the child analyzes, never to an importing module.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

fixture=tests/semantic/Notation.lean
maxb=8589934592

LEAN_NUM_THREADS=1 lake setup-file "$fixture" >"$work/setup.json"

# --- Production capture, both gating directions ---------------------------------------------------
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/setup.json" "$fixture" "$fixture" "$maxb" 1 >"$work/on.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/setup.json" "$fixture" "$fixture" "$maxb" 0 >"$work/off.json"
# A second capturing run must be byte-identical to the first (stable v4 digest / cache identity).
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/setup.json" "$fixture" "$fixture" "$maxb" 1 >"$work/on2.json"

# --- Lean's own emission (the independent oracle) -------------------------------------------------
LEAN_NUM_THREADS=1 lake env lean tests/semantic/Emit.lean >"$work/emit.txt"

python3 - "$work/on.json" "$work/off.json" "$work/on2.json" "$work/emit.txt" <<'PY'
import json, sys
on = json.load(open(sys.argv[1]))["artifact"]
off = json.load(open(sys.argv[2]))["artifact"]
on2 = json.load(open(sys.argv[3]))["artifact"]
emit = open(sys.argv[4]).read().splitlines()

# Both schemas advanced to v4 regardless of capture; only the semantic field differs.
assert on["schema"] == off["schema"] == "lean-fmt.module-artifact.v4", on["schema"]

# B. Demand-gating: no capture -> semantic is null; capture -> semantic present. The source
# projection is byte-identical either way, so the fact is purely additive and the syntax-only path is
# untouched (only the schema tag advances to v4).
assert off["semantic"] is None, f"captureSemantic=0 still captured: {off['semantic']}"
assert on["semantic"] is not None, "captureSemantic=1 produced no semantic fact"
assert on["source"] == off["source"], "semantic capture perturbed the source projection"

# C. The v4 artifact is byte-stable across identical runs (a stable cache digest).
assert on == on2, "two identical capturing runs produced different artifacts"

spacing = {n["kind"]: n["atoms"] for n in on["semantic"]["notations"]}
plus = spacing["«term_+_»"]
times = spacing["«term_*_»"]
corpus = spacing["«term_⊕corpus_»"]
# Each is a single symbolic atom carrying its declared, untrimmed spacing.
assert plus == [" + "], plus
assert times == [" * "], times
assert corpus == [" ⊕corpus "], corpus

# A. Fresh-frontend differential: the captured atoms predict Lean's own emission byte for byte. The
# emission was produced by `ppTerm` in a separate process that never touched the capture code.
core_emitted, corpus_emitted = emit[0], emit[1]
core_predicted = "1" + plus[0] + "2" + times[0] + "3"   # 1 + (2 * 3)
corpus_predicted = "1" + corpus[0] + "2"
assert core_predicted == core_emitted, f"core: {core_predicted!r} != {core_emitted!r}"
assert corpus_predicted == corpus_emitted, f"corpus: {corpus_predicted!r} != {corpus_emitted!r}"

# A'. Non-vacuity: a wrong atom must NOT reproduce the emission. If it did, the differential would
# accept anything and prove nothing.
assert "1" + " - " + "2" + times[0] + "3" != core_emitted, "core differential is vacuous"
assert "1" + " WRONG " + "2" != corpus_emitted, "corpus differential is vacuous"

print("differential: core", repr(core_emitted), "corpus", repr(corpus_emitted))
print("captured atoms:", {"+" : plus, "*": times, "⊕corpus": corpus})
PY

# --- Demand-gating end to end: format rejects the plugin's semantic=none artifact ----------------
# `format` demands `.semantic`; the always-on plugin artifact carries `semantic = none`, so a format
# run must reject it and re-run `analyzeExact`. With the analyzer disabled that re-run fails (exit 2)
# — the rejection made observable. `check` on the same file needs only source-tier facts, accepts the
# cheap artifact, and succeeds (exit 0). The pair is the fast path and the demand seam at once.
clean=tests/check/Clean.lean
set +e
LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" format --root . --json --no-cache "$clean" \
  >"$work/fmt.json" 2>/dev/null
fmt_exit=$?
LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json --no-cache "$clean" \
  >"$work/chk.json" 2>/dev/null
chk_exit=$?
set -e
if [[ $fmt_exit -ne 2 ]]; then
  printf 'format should reject the semantic=none artifact and fail (exit 2), got %s\n' "$fmt_exit" >&2
  cat "$work/fmt.json" >&2
  exit 1
fi
if [[ $chk_exit -ne 0 ]]; then
  printf 'check should serve source-tier from the artifact (exit 0), got %s\n' "$chk_exit" >&2
  cat "$work/chk.json" >&2
  exit 1
fi
grep -q 'infrastructure-failure' "$work/fmt.json" \
  || { echo 'format did not reach the disabled analyzer — it may have accepted the fact-free artifact' >&2; exit 1; }

printf 'lean-fmt semantic differential + demand-gating tests passed\n'
