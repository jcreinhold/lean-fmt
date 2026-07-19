#!/usr/bin/env bash
set -euo pipefail

# The import-rule pipeline end-to-end (`RIR-IMPL`): the three `imports`-category diagnostics and the
# opt-in organizer, on committed module fixtures rather than runtime-crafted strings. The unit and
# characterization tests in `LeanFmtTest.lean` (`testImports`) pin the pure header rules and the
# organizer function; this pins the whole CLI path — read, normalize, parse the surface header, merge
# fresh import findings (FMT006 via the live Lake graph), select, report, and — for the organizer and
# `fix` — validate the rewrite by re-elaboration before writing.
#
# Import findings are computed fresh every run and never cached (FMT005/07 are pure over the file, but
# FMT006 reads *other* files through the graph), so these fixtures use the exact-frontend fallback
# (`LEAN_FMT_DISABLE_ARTIFACT` + `LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE`): the analyzer runs, but the
# import layer is orthogonal to it. FMT006 still resolves through the real workspace.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
cache_root="$repo_root/.lean-fmt-cache"
trap 'rm -rf "$work" "$cache_root" "$repo_root/tests/imports/_fixconflict_tmp.lean"' EXIT

cd "$repo_root"
rm -rf "$cache_root"
LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

fallback=(env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1)

snapshot_metadata() {
  python3 - "$@" <<'PY'
import hashlib, os, sys
for name in sys.argv[1:]:
    data = open(name, "rb").read()
    print(name, hashlib.sha256(data).hexdigest(), os.stat(name).st_mtime_ns)
PY
}

sources=(
  tests/imports/Duplicate.lean
  tests/imports/Ordering.lean
  tests/imports/Redundant.lean
  tests/imports/Suppressed.lean
)
snapshot_metadata "${sources[@]}" >"$work/before"

run_expect() {
  local expected=$1
  local output=$2
  shift 2
  set +e
  "$@" >"$output" 2>"$output.stderr"
  local actual=$?
  set -e
  if [[ $actual -ne $expected ]]; then
    printf 'expected exit %s, got %s\n' "$expected" "$actual" >&2
    cat "$output" >&2
    cat "$output.stderr" >&2
    exit 1
  fi
}

# FMT005: an exact duplicate fires once with a safe fix; nothing is withheld.
run_expect 1 "$work/duplicate.json" "${fallback[@]}" "$application" check --root . --json \
  --no-cache --select imports tests/imports/Duplicate.lean
python3 - "$work/duplicate.json" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
assert file["status"] == "findings", file["status"]
codes = [(f["code"], f.get("fix", {}).get("applicability")) for f in file["findings"]]
assert codes == [("FMT005", "safe")], codes
PY

# FMT007: two imports out of order in one group; report-only (no fix in the finding).
run_expect 1 "$work/ordering.json" "${fallback[@]}" "$application" check --root . --json \
  --no-cache --select imports tests/imports/Ordering.lean
python3 - "$work/ordering.json" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
codes = [f["code"] for f in file["findings"]]
assert codes == ["FMT007"], codes
assert all("fix" not in f for f in file["findings"]), file["findings"]
PY

# FMT006: `LeanFmt.Rules` is in `LeanFmt.Config`'s transitive closure, fetched from the live Lake
# graph, so the plain `import LeanFmt.Rules` is a redundancy candidate. Report-only; nothing withheld.
run_expect 1 "$work/redundant.json" "${fallback[@]}" "$application" check --root . --json \
  --no-cache --select imports tests/imports/Redundant.lean
python3 - "$work/redundant.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
file, = report["files"]
codes = [f["code"] for f in file["findings"]]
assert codes == ["FMT006"], codes
assert all("fix" not in f for f in file["findings"]), file["findings"]
assert report["withheldRedundant"] == 0, report["withheldRedundant"]
PY

# Selection is honored: `--select FMT005` on the out-of-order fixture reports nothing (FMT007 is not
# selected), proving import codes flow through the same selection projection as any rule.
run_expect 0 "$work/select-fmt005.json" "${fallback[@]}" "$application" check --root . --json \
  --no-cache --select FMT005 tests/imports/Ordering.lean
python3 - "$work/select-fmt005.json" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
assert [f["code"] for f in file["findings"]] == [], file["findings"]
PY

# The organizer, dry run: `--check` reports a pending change and exits 1 without touching the file.
run_expect 1 "$work/organize-check.json" "$application" organize --check --root . --json \
  tests/imports/Ordering.lean
python3 - "$work/organize-check.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["mode"] == "organize", report["mode"]
file, = report["files"]
assert file["status"] == "would-organize", file["status"]
assert report["written"] == 0, report
PY

# The organizer, write: sort the group by module name, validated by re-elaboration, then restore.
cp -p tests/imports/Ordering.lean "$work/Ordering.backup"
run_expect 0 "$work/organize-write.json" "$application" organize --root . --json \
  tests/imports/Ordering.lean
python3 - "$work/organize-write.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
file, = report["files"]
assert file["status"] == "organized" and report["written"] == 1, report
PY
python3 - tests/imports/Ordering.lean <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
imports = [l for l in lines if l.startswith("import ")]
assert imports == ["import LeanFmt.Basic", "import LeanFmt.Digest"], imports
PY
cp -p "$work/Ordering.backup" tests/imports/Ordering.lean

# `fix` applies the FMT005 safe dedup through the canonical patch (the printer keeps the duplicate, so
# the fix is recomputed at canonical coordinates), validated and written; then restore.
cp -p tests/imports/Duplicate.lean "$work/Duplicate.backup"
run_expect 0 "$work/fix.json" "$application" fix --root . --json --no-cache \
  --select imports tests/imports/Duplicate.lean
python3 - "$work/fix.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
file, = report["files"]
assert file["status"] == "fixed" and report["written"] == 1, report
PY
python3 - tests/imports/Duplicate.lean <<'PY'
import sys
imports = [l for l in open(sys.argv[1]).read().splitlines() if l.startswith("import ")]
assert imports == ["import LeanFmt.Basic"], imports
PY
cp -p "$work/Duplicate.backup" tests/imports/Duplicate.lean

# RIR-FINAL differentials, run as persistent guards.

# Suppression composes with the import layer: a trailing `ignore[FMT005]` on the duplicate line
# suppresses the import finding through the same post-cache projection every rule flows through, so the
# file reports clean with the suppression counted (an import finding is not special to suppression).
run_expect 0 "$work/suppressed.json" "${fallback[@]}" "$application" check --root . --json \
  --no-cache --select imports tests/imports/Suppressed.lean
python3 - "$work/suppressed.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
file, = report["files"]
assert file["status"] == "clean" and file["findings"] == [], file
assert report["suppressed"] == 1, report["suppressed"]
PY

# Order is elaboration-significant, so the default `fix` must NEVER reorder a header — FMT007 carries
# no fix, and only the explicit `organize` command rewrites. `fix` on the out-of-order fixture leaves
# the written order untouched.
cp -p tests/imports/Ordering.lean "$work/Ordering.fixbackup"
run_expect 0 "$work/fix-noreorder.json" "${fallback[@]}" "$application" fix --root . --json \
  --no-cache tests/imports/Ordering.lean
python3 - tests/imports/Ordering.lean <<'PY'
import sys
imports = [l for l in open(sys.argv[1]).read().splitlines() if l.startswith("import ")]
assert imports == ["import LeanFmt.Digest", "import LeanFmt.Basic"], imports
PY
cp -p "$work/Ordering.fixbackup" tests/imports/Ordering.lean

# The split, on the load-bearing FMT005 regression: a file with a duplicate import (FMT005) AND trailing
# whitespace. Since `ruff-11c` RDF-IMPL `fix` applies rule fixes at original coordinates and owns no
# layout, while `format` owns layout and applies no fix — the decoupling `tests/modes` proves end to end.
# So on this one file the two modes touch disjoint bytes. Built at runtime under the root (so the
# workspace resolves) and removed after.
conflict=tests/imports/_fixconflict_tmp.lean
seed() { printf 'module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n\ndef importFixConflictNoop : Nat := 0  \n' >"$conflict"; }
# `fix` removes the duplicate import at its original coordinates and validates by re-elaboration, but
# leaves the trailing whitespace — layout is not fix's job.
seed
run_expect 0 "$work/fix-conflict.json" "${fallback[@]}" "$application" fix --root . --json \
  --no-cache "$conflict"
python3 - "$work/fix-conflict.json" "$conflict" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
file, = report["files"]
assert file["status"] == "fixed" and report["written"] == 1, report
text = open(sys.argv[2]).read()
imports = [l for l in text.splitlines() if l.startswith("import ")]
assert imports == ["import LeanFmt.Basic"], imports          # FMT005 fix applied at original coords
assert text.endswith("0  \n"), repr(text)                    # trailing whitespace UNTOUCHED — layout is format's
PY
# `format` owns the inverse half: it trims the trailing whitespace but applies no FMT005 fix, so both
# imports survive and the duplicate is reported, not removed.
seed
run_expect 1 "$work/format-conflict.json" "${fallback[@]}" "$application" format --root . --json \
  --no-cache "$conflict"
python3 - "$work/format-conflict.json" "$conflict" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
assert file["status"] == "would-format", file
out = file["formatted"]
imports = [l for l in out.splitlines() if l.startswith("import ")]
assert imports == ["import LeanFmt.Basic", "import LeanFmt.Basic"], imports  # NO fix — duplicate kept
assert "  \n" not in out and not out.rstrip("\n").endswith(" "), repr(out)   # layout trimmed
assert "FMT005" in [f["code"] for f in file["findings"]], file["findings"]   # reported, not removed
PY
rm -f "$conflict"

snapshot_metadata "${sources[@]}" >"$work/after"
cmp "$work/before" "$work/after"

printf 'lean-fmt import-rule integration tests passed\n'
