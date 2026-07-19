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
# Build the exe and refresh the Clean fixture's artifact facet: a schema bump (here v4→v5) changes the
# compiler plugin, so a stale on-disk artifact is correctly rejected by the schema guard. The
# demand-gating sub-check below needs Clean's facet current, so rebuild it rather than serve a stale
# artifact the new code (correctly) refuses.
LEAN_NUM_THREADS=1 lake build lean-fmt Clean:leanFmtArtifact
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

# Both schemas advanced to v5 regardless of capture; only the semantic field differs.
assert on["schema"] == off["schema"] == "lean-fmt.module-artifact.v5", on["schema"]

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

# --- ruff-11 RMR-IMPL: the surfaced-diagnostics differential --------------------------------------
# The production capture path (`__analyze-exact ... 1`) normalizes the compiler's own diagnostics into
# the artifact's `semantic.diagnostics`. Prove the captured `(kind, range)` reproduces what Lean's own
# `--json` frontend emits on the same fixture — an independent oracle that never touches the capture
# code — for all four surfaced kinds, and that capture=0 carries no diagnostics (demand-gating).
diag=tests/semantic/Diagnostics.lean
LEAN_NUM_THREADS=1 lake setup-file "$diag" >"$work/dsetup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/dsetup.json" "$diag" "$diag" "$maxb" 1 >"$work/don.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/dsetup.json" "$diag" "$diag" "$maxb" 0 >"$work/doff.json"
LEAN_NUM_THREADS=1 lake env lean --json "$diag" >"$work/doracle.json" 2>/dev/null || true

python3 - "$work/don.json" "$work/doff.json" "$work/doracle.json" "$diag" <<'PY'
import json, sys
captured = json.load(open(sys.argv[1]))["artifact"]["semantic"]["diagnostics"]
off = json.load(open(sys.argv[2]))["artifact"]["semantic"]
source = open(sys.argv[4], "rb").read()

# Demand-gating: capture=0 carries no semantic fact at all (so no diagnostics either).
assert off is None, f"captureSemantic=0 still captured diagnostics: {off}"

want = {
    "Lean.Linter.deprecatedAttr",       # FMT014
    "linter.unusedVariables",           # FMT015
    "linter.unusedSectionVars",         # FMT016
    "linter.constructorNameAsVariable", # FMT017
}
got_kinds = {d["kind"] for d in captured}
assert want <= got_kinds, f"missing surfaced kinds: {want - got_kinds} (got {got_kinds})"

# Only the surfaced kinds are captured — the artifact never carries a diagnostic no rule reads.
assert got_kinds <= want, f"captured unowned kinds: {got_kinds - want}"

# Every captured range is inside the module's own bytes and well-formed.
n = len(source)
for d in captured:
    r = d["range"]
    assert 0 <= r["start"] <= r["stop"] <= n, f"range out of bounds: {d}"

# Independent oracle: Lean's own `--json` positions, converted to byte offsets, must match a captured
# diagnostic of the same kind. This is the "the fact is the compiler's, not ours" differential.
def byte_offset(line, col):
    # `--json` gives 1-based line, 0-based utf-8-codepoint column? Lean columns are codepoint indices.
    lines = source.split(b"\n")
    off = sum(len(lines[i]) + 1 for i in range(line - 1))
    # advance `col` codepoints into the line
    return off + len(lines[line - 1].decode("utf-8")[:col].encode("utf-8"))

oracle = [json.loads(l) for l in open(sys.argv[3]) if l.strip().startswith("{")]
matched = 0
for o in oracle:
    if o.get("kind") not in want:
        continue
    start = byte_offset(o["pos"]["line"], o["pos"]["column"])
    hit = [d for d in captured if d["kind"] == o["kind"] and d["range"]["start"] == start]
    assert hit, f"no captured diagnostic matches oracle {o['kind']} at byte {start}"
    matched += 1
assert matched >= 4, f"oracle matched only {matched} diagnostics"
print("diagnostics differential: matched", matched, "kinds", sorted(got_kinds))
PY

# --- ruff-11 RMR-FINAL: end-to-end acceptance -----------------------------------------------------
# Three product behaviors under a semantic `--select`, proven through the real `check`/`fix` CLI on a
# throwaway project (a project so error and trailing-whitespace fixtures need not be committed — `git
# diff --check` forbids trailing whitespace in tracked files):
#   1. an elaboration ERROR is REPORTED broken, never silently omitted (`prompts/03` headline stop-rule);
#   2. a mixed source+semantic selection reports both tiers' findings in one run;
#   3. `fix` over a report-only semantic rule writes nothing.
# Plus a named-stress cost measurement: the diagnostics capture is additive (capture-on peak RSS ≈
# capture-off), well inside the 8 GiB envelope. Full mathlib is forbidden here (`prompts/03` Check).
proj="$work/proj"
mkdir -p "$proj/acc"
cp lean-toolchain "$proj/lean-toolchain"
cat >"$proj/lakefile.lean" <<'LEAN'
import Lake
open Lake DSL
package "ruff11acc"
lean_lib Demo where
  roots := #[`Demo]
  globs := #[Glob.one `Demo]
LEAN
# A clean library file so the package builds; the acceptance fixtures sit outside its glob (like
# `tests/scale`'s standalone source) so an intentionally-broken fixture never fails `lake build`.
cat >"$proj/Demo.lean" <<'LEAN'
module

def demo : Nat := 1
LEAN
# Elaboration ERROR fixture (a type mismatch): `analyzeExact` returns `broken`. With a semantic rule
# selected the run demands `.semantic`, and a broken analysis must still surface as a reported file.
cat >"$proj/acc/Broken.lean" <<'LEAN'
module

def bad : Nat := true
LEAN
# Mixed-tier fixture: a deprecated use (FMT014, semantic) AND trailing whitespace (FMT001, source) on
# the `useOld` line — the trailing spaces are literal, written via printf.
{
  printf 'module\n\n'
  printf 'def newName : Nat := 1\n'
  printf '@[deprecated newName (since := "2024-01-01")]\n'
  printf 'def oldName : Nat := 0\n'
  printf 'def useOld : Nat := oldName   \n'
} >"$proj/acc/Mixed.lean"
LEAN_NUM_THREADS=1 lake -d "$proj" build Demo >/dev/null

check_exit() {  # run a command, capture its exit code into $ACC_EXIT (never aborts the harness)
  set +e; "$@"; ACC_EXIT=$?; set -e
}

# 1. Silent-omission-on-error. A semantic selection over a file that fails to elaborate reports the
# file `broken` (exit 1, `broken == 1`), never dropping it from `files`.
check_exit env LEAN_NUM_THREADS=1 "$application" check --root "$proj" --json --no-cache \
  --select FMT014 "$proj/acc/Broken.lean" >"$work/acc-broken.json" 2>/dev/null
if [[ $ACC_EXIT -ne 1 ]]; then
  printf 'check over a broken file under a semantic selection: expected exit 1, got %s\n' "$ACC_EXIT" >&2
  cat "$work/acc-broken.json" >&2; exit 1
fi
python3 - "$work/acc-broken.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
files = {f["path"]: f["status"] for f in r["files"]}
assert files == {"acc/Broken.lean": "broken"}, files       # present and broken, NOT omitted
assert r["broken"] == 1 and not r["infrastructureFailures"], r
PY

# 2. Mixed-tier selection. `--select FMT001 --select FMT014` demands `.semantic` (the max of the two
# tiers), runs the whole registry over the semantic facts, and reports both a semantic and a source
# finding on the one file — byte-sorted, independent of registry order.
check_exit env LEAN_NUM_THREADS=1 "$application" check --root "$proj" --json --no-cache \
  --select FMT001 --select FMT014 "$proj/acc/Mixed.lean" >"$work/acc-mixed.json" 2>/dev/null
python3 - "$work/acc-mixed.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
f, = r["files"]
codes = [x["code"] for x in f["findings"]]
assert "FMT014" in codes, codes    # deprecated use — the semantic tier
assert "FMT001" in codes, codes    # trailing whitespace — the source tier, in the same report
# The semantic finding preserves the compiler's own deprecation message.
dep = next(x for x in f["findings"] if x["code"] == "FMT014")
assert "deprecated" in dep["message"].lower(), dep
print("mixed-tier: one run reported", sorted(set(codes)))
PY

# 3. Fix over a report-only semantic rule writes nothing. FMT014 carries no fix, so a `fix` selecting
# only it publishes no patch: the file is byte-identical afterward and the report shows no write.
cp "$proj/acc/Mixed.lean" "$work/mixed.orig"
check_exit env LEAN_NUM_THREADS=1 "$application" fix --root "$proj" --json --no-cache \
  --select FMT014 "$proj/acc/Mixed.lean" >"$work/acc-fix.json" 2>/dev/null
python3 - "$work/acc-fix.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 0 and r["changed"] == 0, r    # report-only: nothing published
PY
cmp -s "$work/mixed.orig" "$proj/acc/Mixed.lean" \
  || { echo 'fix over a report-only semantic rule modified the source' >&2; exit 1; }

# 4. Cost — the diagnostics capture is additive. `$work/don.json` (capture=1) and `$work/doff.json`
# (capture=0) above already prove the source projection is byte-identical either way; here we measure
# peak RSS with `/usr/bin/time -l` (Darwin) and assert capture-on stays inside the envelope and does
# not balloon over capture-off. Best-effort: if the tool/field is unavailable the check is skipped.
if /usr/bin/time -l true >/dev/null 2>&1; then
  rss_of() {  # peak RSS (bytes) of one `__analyze-exact` run at capture flag $1
    /usr/bin/time -l env LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
      "$work/dsetup.json" "$diag" "$diag" "$maxb" "$1" >/dev/null 2>"$work/time$1.txt"
    grep "maximum resident set size" "$work/time$1.txt" | awk '{print $1}'
  }
  on_rss=$(rss_of 1); off_rss=$(rss_of 0)
  python3 - "$on_rss" "$off_rss" <<'PY'
import sys
on, off = int(sys.argv[1]), int(sys.argv[2])
gib = 8 * 1024**3
assert on < gib, f"capture-on peak RSS {on} exceeds the 8 GiB envelope"
# Additive: capturing the already-collected MessageLog must not multiply memory. 1.5x is generous
# headroom over the observed ~parity (both ~636 MiB on the named stress fixture).
assert on <= off * 3 // 2, f"capture-on RSS {on} ballooned over capture-off {off}"
print(f"cost: capture-on peak RSS {on//1048576} MiB vs capture-off {off//1048576} MiB (additive)")
PY
else
  echo "cost: /usr/bin/time -l unavailable — RSS additivity check skipped"
fi

printf 'lean-fmt semantic differential + demand-gating + RMR-FINAL acceptance tests passed\n'
