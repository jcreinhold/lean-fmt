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

# Both schemas advanced to v6 regardless of capture; only the semantic field differs.
assert on["schema"] == off["schema"] == "lean-fmt.module-artifact.v6", on["schema"]

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

# --- ruff-11b ROS-IMPL: the owned occurrence fact, its differential, and its demand-gating -----------
# The owned deprecation-occurrence fact is captured only under the *occurrences* capability (token "2"),
# never the plain semantic capture (token "1"). Prove both directions of demand-gating, and that the
# captured occurrence `(range, declName, newName?)` matches Lean's own resolution — the deprecatedAttr
# diagnostic the compiler emitted at the very same byte, an independent oracle over the same fixture.
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/dsetup.json" "$diag" "$diag" "$maxb" 2 >"$work/docc.json"

python3 - "$work/don.json" "$work/docc.json" "$work/doracle.json" "$diag" <<'PY'
import json, sys
sem_semantic = json.load(open(sys.argv[1]))["artifact"]["semantic"]     # token "1"
occ_semantic = json.load(open(sys.argv[2]))["artifact"]["semantic"]     # token "2"
source = open(sys.argv[4], "rb").read()

# Demand-gating, both directions: the plain semantic capture (token "1") does NOT run the info-tree
# fold, so `occurrences` is null (the `none` Option); the occurrences capability (token "2") captures
# it (a list). Lean's derived `ToJson` strips the trailing `?` from an Option field's name, so the
# `occurrences?`/`newName?`/`since?` fields serialize under `occurrences`/`newName`/`since`.
assert sem_semantic.get("occurrences") is None, \
    f"token 1 captured occurrences (info-tree walk not gated): {sem_semantic.get('occurrences')}"
occ = occ_semantic["occurrences"]
assert isinstance(occ, list) and len(occ) >= 1, f"token 2 captured no occurrences: {occ}"

# The fixture's one deprecated USE is `def useOld : Nat := oldName`. The declaration site `def oldName`
# is a binder and must be excluded, so exactly the use is recorded (deduplicated to one entry).
uses = [o for o in occ if o["declName"].split(".")[-1] == "oldName"]
assert len(uses) == 1, f"expected exactly one `oldName` use occurrence (binder excluded), got {uses}"
u = uses[0]
assert u["newName"] is not None and u["newName"].split(".")[-1] == "newName", u
assert u["fixable"] is True, f"a bare-identifier deprecated use must be fixable: {u}"

# The occurrence range spells exactly the identifier, and it is NOT the declaration-site `oldName`
# (that leading occurrence is `def oldName`; the use is the trailing one).
r = u["range"]
assert source[r["start"]:r["stop"]] == b"oldName", (r, source[r["start"]:r["stop"]])
decl_pos = source.index(b"def oldName") + len(b"def ")
assert r["start"] != decl_pos, "binder (declaration-site) occurrence was not excluded"

# Differential: the occurrence resolves at the exact byte Lean's own deprecation diagnostic points to.
def byte_offset(line, col):
    lines = source.split(b"\n")
    off = sum(len(lines[i]) + 1 for i in range(line - 1))
    return off + len(lines[line - 1].decode("utf-8")[:col].encode("utf-8"))

oracle = [json.loads(l) for l in open(sys.argv[3]) if l.strip().startswith("{")]
dep = [o for o in oracle if o.get("kind") == "Lean.Linter.deprecatedAttr"]
assert dep, "oracle emitted no deprecation diagnostic to differential against"
starts = {byte_offset(o["pos"]["line"], o["pos"]["column"]) for o in dep}
assert r["start"] in starts, \
    f"occurrence at byte {r['start']} does not match Lean's deprecation resolution {sorted(starts)}"
print("occurrence differential: use of", u["declName"].split(".")[-1], "->", u["newName"].split(".")[-1],
      "at byte", r["start"], "(matches Lean); token-1 occurrences null, token-2 present")
PY

# --- ruff-11b ROS-FINAL: the fixable-occurrence predicate, adversarially ------------------------------
# The capture-side predicate (`Analysis.occurrenceOfInfo`, `notes/01-model.md` §5) must mark an
# occurrence `fixable` ONLY when its source spelling is exactly the resolved constant's own full display
# name — so a whole-span replacement with the new full name re-resolves unambiguously. Every other
# spelling stays report-only. `Occurrences.lean` is the adversarial fixture; token "2" captures it and
# we assert the fixable flag per spelling. A regression here is a soundness bug: a wrong `fixable=true`
# would let `fix --unsafe-fixes` corrupt a dot-notation or `open`-shadowed use.
occf=tests/semantic/Occurrences.lean
LEAN_NUM_THREADS=1 lake setup-file "$occf" >"$work/osetup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/osetup.json" "$occf" "$occf" "$maxb" 2 >"$work/occ.json"
python3 - "$work/occ.json" "$occf" <<'PY'
import json, sys
sem = json.load(open(sys.argv[1]))["artifact"]["semantic"]
src = open(sys.argv[2], "rb").read()
occ = sem["occurrences"]
# Index every occurrence by its spelled source text (dedup already applied at capture).
by_spelled = {}
for o in occ:
    r = o["range"]
    by_spelled.setdefault(src[r["start"]:r["stop"]].decode("utf-8"), o)

def check(spelled, want_fixable, want_decl):
    o = by_spelled.get(spelled)
    assert o is not None, f"no occurrence spelled {spelled!r} (captured: {sorted(by_spelled)})"
    assert o["fixable"] is want_fixable, \
        f"occurrence {spelled!r} (declName {o['declName']}) fixable={o['fixable']}, expected {want_fixable}"
    assert o["declName"] == want_decl, f"{spelled!r} declName={o['declName']}, expected {want_decl}"

# Fixable: a bare top-level use, and a fully-qualified use whose whole span is the constant's own name.
check("oldBare", True, "oldBare")            # bare identifier == full name
check("N.oldNs", True, "N.oldNs")            # fully-qualified use == full name (whole span replaced)
# Report-only: the spelling is NOT the constant's full name — a rename cannot be proven textually.
check("oldNs", False, "N.oldNs")             # `open`-shadowed short name (resolves to N.oldNs)
check("oldGet", False, "Wrap.oldGet")        # dot-notation projection head (`w.oldGet`)
check("oldNoRepl", False, "oldNoRepl")       # `newName? = none` — nothing to substitute
# No occurrence is fixable unless it carries a replacement name.
assert all((not o["fixable"]) or (o.get("newName") is not None) for o in occ), \
    "an occurrence is fixable without a replacement name"
print("fixable predicate:", {s: by_spelled[s]["fixable"] for s in
      ("oldBare", "N.oldNs", "oldNs", "oldGet", "oldNoRepl")})
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
# Mixed-tier fixture: a deprecated use (FMT014, semantic) on the `useOld` line AND a redundant nested
# paren (FMT013, syntax) on the `parened` line. Before `ruff-11c` RDF-LAYOUT this paired FMT014 with a
# trailing-whitespace FMT001; that source rule retired into the formatter's layout, so a genuine
# syntax-tier rule (FMT013) now stands in — still a strictly cheaper tier than the semantic FMT014, so
# `max` still lands on `.semantic`, and FMT013 also carries a safe fix for the pass-order case below.
{
  printf 'module\n\n'
  printf 'def newName : Nat := 1\n'
  printf '@[deprecated newName (since := "2024-01-01")]\n'
  printf 'def oldName : Nat := 0\n'
  printf 'def useOld : Nat := oldName\n'
  printf 'def parened : Nat := ((1))\n'
} >"$proj/acc/Mixed.lean"
LEAN_NUM_THREADS=1 lake -d "$proj" build Demo >/dev/null

check_exit() {  # run a command, capture its exit code into $ACC_EXIT (never aborts the harness)
  set +e; "$@"; ACC_EXIT=$?; set -e
}

# 1. Silent-omission-on-error. A semantic selection over a file that fails to elaborate reports the
# file `broken` (exit 1, `broken == 1`), never dropping it from `files`.
check_exit env LEAN_NUM_THREADS=1 "$application" check --root "$proj" --json --no-cache --preview \
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

# 2. Mixed-tier selection. `--select FMT013 --select FMT014` demands `.semantic` (the max of the two
# tiers), runs the whole registry over the semantic facts, and reports both a semantic and a syntax
# finding on the one file — byte-sorted, independent of registry order.
check_exit env LEAN_NUM_THREADS=1 "$application" check --root "$proj" --json --no-cache --preview \
  --select FMT013 --select FMT014 "$proj/acc/Mixed.lean" >"$work/acc-mixed.json" 2>/dev/null
python3 - "$work/acc-mixed.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
f, = r["files"]
codes = [x["code"] for x in f["findings"]]
assert "FMT014" in codes, codes    # deprecated use — the semantic tier
assert "FMT013" in codes, codes    # redundant nested paren — the syntax tier, in the same report
# The semantic finding preserves the compiler's own deprecation message.
dep = next(x for x in f["findings"] if x["code"] == "FMT014")
assert "deprecated" in dep["message"].lower(), dep
print("mixed-tier: one run reported", sorted(set(codes)))
PY

# 3. Withheld (unadmitted) owned fix. FMT014's rename is `.unsafe` (`ruff-11b`): without `--unsafe-fixes`
# it is *withheld*, so a `fix` selecting only it publishes no patch — the file is byte-identical
# afterward, the report shows no write, and the withheld-unsafe count records the omission (so the
# report never reads as "clean, nothing to fix" for a file that has a fix nobody admitted).
cp "$proj/acc/Mixed.lean" "$work/mixed.orig"
check_exit env LEAN_NUM_THREADS=1 "$application" fix --root "$proj" --json --no-cache --preview \
  --select FMT014 "$proj/acc/Mixed.lean" >"$work/acc-fix.json" 2>/dev/null
python3 - "$work/acc-fix.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 0 and r["changed"] == 0, r          # unadmitted: nothing published
assert r["withheldUnsafe"] >= 1, r                         # ...but the fix exists and was withheld
PY
cmp -s "$work/mixed.orig" "$proj/acc/Mixed.lean" \
  || { echo 'fix withholding an unsafe owned fix modified the source' >&2; exit 1; }

# 3b. Admitted owned fix applies a real rename. Since `ruff-11c` RDF-IMPL `fix` applies the FMT014
# occurrence edit at its original-source coordinates and owns no reflow (the retired `reprojectCanonical`
# canonical-coordinate path is gone). `fix --unsafe-fixes --select FMT014` publishes the rename
# `oldName -> newName`: the file changes, the written use reads `newName`, and a re-`check` of FMT014 is
# clean because the only deprecated use is gone.
check_exit env LEAN_NUM_THREADS=1 "$application" fix --root "$proj" --json --no-cache --preview \
  --unsafe-fixes --select FMT014 "$proj/acc/Mixed.lean" >"$work/acc-apply.json" 2>/dev/null
python3 - "$work/acc-apply.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 1 and r["changed"] == 1, r          # admitted: the rename is published
assert r["rejected"] == 0, r                               # a `written` fix already passed the validator
PY
grep -q 'def useOld : Nat := newName' "$proj/acc/Mixed.lean" \
  || { echo 'admitted owned fix did not rename oldName -> newName' >&2; cat "$proj/acc/Mixed.lean" >&2; exit 1; }
if grep 'useOld' "$proj/acc/Mixed.lean" | grep -q 'oldName'; then
  echo 'the deprecated name survives on the use line after the fix' >&2; exit 1
fi
# The rename re-elaborates (the exact frontend runs fresh under `--no-cache`) and leaves no deprecated
# use: a fresh check of FMT014 is clean.
check_exit env LEAN_NUM_THREADS=1 "$application" check --root "$proj" --json --no-cache --preview \
  --select FMT014 "$proj/acc/Mixed.lean" >"$work/acc-recheck.json" 2>/dev/null
python3 - "$work/acc-recheck.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
f, = r["files"]
codes = [x["code"] for x in f["findings"]]
assert "FMT014" not in codes, codes                        # the deprecated use is gone
PY

# 3b'. The inverse half of the split, on the owned semantic fix. `format` owns no rule fix: on a fresh
# copy of the original (deprecated `oldName` use intact), `format --unsafe-fixes --select FMT014` renders
# layout only and never renames — `useOld := oldName` survives byte-for-byte, where `fix` above published
# `newName`. This is the RDF-IMPL decoupling on the FMT014 rename: applied by `fix` at original
# coordinates, absent from `format`. (`--unsafe-fixes` is a no-op for `format` — it admits nothing to apply.)
cp "$work/mixed.orig" "$proj/acc/MixedFmt.lean"
check_exit env LEAN_NUM_THREADS=1 "$application" format --check --root "$proj" --json --no-cache --preview \
  --unsafe-fixes --select FMT014 "$proj/acc/MixedFmt.lean" >"$work/acc-format.json" 2>/dev/null
python3 - "$work/acc-format.json" <<'PY'
import json, sys
f, = json.load(open(sys.argv[1]))["files"]
out = f["formatted"]
assert out is None or ("oldName" in out and "def useOld : Nat := newName" not in out), \
  ("format applied the FMT014 rename — it must not", repr(out))
PY
grep -q 'def useOld : Nat := oldName' "$proj/acc/MixedFmt.lean" \
  || { echo 'format mutated the deprecated use — it must not write, let alone rename' >&2; exit 1; }
rm -f "$proj/acc/MixedFmt.lean"

# 3c. Idempotence. A second `fix --unsafe-fixes --select FMT014` over the already-renamed file is a
# no-op: nothing left to rename, so no write and the bytes are unchanged.
cp "$proj/acc/Mixed.lean" "$work/mixed.fixed"
check_exit env LEAN_NUM_THREADS=1 "$application" fix --root "$proj" --json --no-cache --preview \
  --unsafe-fixes --select FMT014 "$proj/acc/Mixed.lean" >"$work/acc-idem.json" 2>/dev/null
python3 - "$work/acc-idem.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 0 and r["changed"] == 0, r          # idempotent: the second fix is a no-op
PY
cmp -s "$work/mixed.fixed" "$proj/acc/Mixed.lean" \
  || { echo 'a second FMT014 fix modified an already-renamed file' >&2; exit 1; }

# 3d. Pass-order independence. `--select` order must not change the published bytes: FMT014 (semantic
# occurrence rename) and FMT013 (syntax, safe paren removal), both at original-source coordinates,
# compose the same either way. Both orders
# `fix --unsafe-fixes` a fresh copy of the original and must write byte-identical output.
cp "$work/mixed.orig" "$proj/acc/OrderA.lean"
cp "$work/mixed.orig" "$proj/acc/OrderB.lean"
LEAN_NUM_THREADS=1 "$application" fix --root "$proj" --json --no-cache --preview --unsafe-fixes \
  --select FMT014 --select FMT013 "$proj/acc/OrderA.lean" >/dev/null 2>&1 || true
LEAN_NUM_THREADS=1 "$application" fix --root "$proj" --json --no-cache --preview --unsafe-fixes \
  --select FMT013 --select FMT014 "$proj/acc/OrderB.lean" >/dev/null 2>&1 || true
cmp -s "$proj/acc/OrderA.lean" "$proj/acc/OrderB.lean" \
  || { echo 'pass order changed the published bytes (FMT014 vs FMT013 order-dependent)' >&2;
       diff "$proj/acc/OrderA.lean" "$proj/acc/OrderB.lean" >&2; exit 1; }
grep -q 'def useOld : Nat := newName' "$proj/acc/OrderA.lean" \
  || { echo 'order-independent fix did not apply the rename' >&2; exit 1; }
rm -f "$proj/acc/OrderA.lean" "$proj/acc/OrderB.lean"
# Restore the fixture for any later reuse.
cp "$work/mixed.orig" "$proj/acc/Mixed.lean"

# 4. Cost (`ruff-11b` ROS-FINAL) — the info-tree walk is the demanded delta the capability split bounds.
# `$work/don.json` (capture=1) and `$work/doff.json` (capture=0) above already prove the source
# projection is byte-identical either way; here we measure peak RSS AND wall time with `/usr/bin/time -l`
# (Darwin) across the three capture levels — surfaced-only (token 1, no walk) vs walk-demanded (token 2)
# vs none (token 0) — and assert the walk-demanded run stays inside the 8 GiB envelope and does not
# balloon over the surfaced-only run. The info trees are already resident (the `messages` walk holds the
# same snapshot tree), so the fold is a read, not a second elaboration. Best-effort: skipped if the
# tool/field is unavailable.
if /usr/bin/time -l true >/dev/null 2>&1; then
  measure() {  # run `__analyze-exact` at capture flag $1, leaving stats in $work/time$1.txt
    /usr/bin/time -l env LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
      "$work/dsetup.json" "$diag" "$diag" "$maxb" "$1" >/dev/null 2>"$work/time$1.txt"
  }
  rss_of()  { grep "maximum resident set size" "$work/time$1.txt" | awk '{print $1}'; }
  real_of() { grep -E "[0-9.]+ real" "$work/time$1.txt" | awk '{print $1}'; }
  measure 0; measure 1; measure 2
  off_rss=$(rss_of 0); on_rss=$(rss_of 1); occ_rss=$(rss_of 2)
  on_real=$(real_of 1); occ_real=$(real_of 2)
  python3 - "$on_rss" "$off_rss" "$occ_rss" "$on_real" "$occ_real" <<'PY'
import sys
on, off, occ = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
on_t, occ_t = float(sys.argv[4]), float(sys.argv[5])
gib = 8 * 1024**3
assert on < gib, f"capture-on peak RSS {on} exceeds the 8 GiB envelope"
# Additive: capturing the already-collected MessageLog must not multiply memory. 1.5x is generous
# headroom over the observed ~parity (both ~636 MiB on the named stress fixture).
assert on <= off * 3 // 2, f"capture-on RSS {on} ballooned over capture-off {off}"
# The `occurrences` capability (token "2") adds the whole-file info-tree fold over already-resident
# trees: its peak must stay inside the envelope and near the diagnostics-only capture, not balloon.
# This is the cost side of the demand-gating — the walk exists only under this token.
assert occ < gib, f"occurrence-capture peak RSS {occ} exceeds the 8 GiB envelope"
assert occ <= off * 3 // 2, f"occurrence capture RSS {occ} ballooned over capture-off {off}"
# Wall time: the fold is a read, so the walk-demanded run stays within a small factor of the
# surfaced-only run (process startup dominates this fixture). 2x is generous headroom over parity.
assert occ_t <= on_t * 2 + 0.5, f"occurrence walk wall time {occ_t}s ballooned over surfaced-only {on_t}s"
print(f"cost: RSS diag-capture {on//1048576} MiB, occ-capture {occ//1048576} MiB "
      f"vs off {off//1048576} MiB; wall surfaced {on_t}s vs walk {occ_t}s (fold is a read)")
PY
else
  echo "cost: /usr/bin/time -l unavailable — RSS/wall additivity check skipped"
fi

printf 'lean-fmt semantic differential + demand-gating + RMR-FINAL acceptance tests passed\n'
