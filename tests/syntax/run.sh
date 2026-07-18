#!/usr/bin/env bash
set -euo pipefail

# The first `syntax`-tier rules (FMT008-FMT013) run against the compiler projection, not the raw
# bytes. These fixtures are deliberately *not* built modules: there is no `.olean`, no module
# evidence, and no artifact for them, so the exact frontend is the only path that can project them.
# `check` on a current built module takes the source-only shortcut and never reaches a syntax rule;
# forcing the exact frontend here is what exercises FMT008-FMT013 at all. Disabling the artifact and
# module evidence makes that explicit rather than dependent on whatever the build tree happens to
# hold, and matches how `tests/check/run.sh` reaches the same fallback.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
cache_root="$repo_root/.lean-fmt-cache"
trap 'rm -rf "$work" "$cache_root"' EXIT

cd "$repo_root"
rm -rf "$cache_root"
LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

# Every syntax-rule invocation goes through the exact frontend. `--no-cache` keeps each run
# independent of the last so a fixture is measured on its own bytes.
sfmt() {
  env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
    "$application" "$@"
}

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

# `select` is one selector per flag; the six preview rules are named explicitly so a negative fixture
# is measured against every rule at once, not just the one it is a near-miss for.
all_six=(--select FMT008 --select FMT009 --select FMT010 --select FMT011 --select FMT012 --select FMT013)

# Assert the exact ordered list of finding codes a single-file `check` reports, and that nothing
# failed infrastructurally. `$1` label, `$2` fixture, `$3` space-separated expected codes (empty for
# a clean/near-miss/exclusion fixture), rest are `check` arguments (the selectors).
expect_codes() {
  local label=$1 fixture=$2 expected=$3
  shift 3
  local exit_code=0
  [[ -n "$expected" ]] && exit_code=1
  run_expect "$exit_code" "$work/$label.json" \
    sfmt check --root . --json --no-cache "$@" "tests/syntax/$fixture"
  EXPECTED="$expected" LABEL="$label" python3 - "$work/$label.json" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
label = os.environ["LABEL"]
expected = os.environ["EXPECTED"].split()
assert len(data["files"]) == 1, (label, data["files"])
got = [f["code"] for f in data["files"][0]["findings"]]
assert got == expected, f"{label}: expected {expected}, got {got}"
assert data["infrastructureFailures"] == [], (label, data["infrastructureFailures"])
assert data["broken"] == 0, (label, data["broken"])
PY
}

# --- Positives: each defect fires exactly its own rule -----------------------------------------
expect_codes fmt008-pos NoModuleDoc.lean  "FMT008" --select FMT008
expect_codes fmt009-pos Unclosed.lean     "FMT009" --select FMT009
expect_codes fmt010-pos Duplicates.lean   "FMT010" --select FMT010
expect_codes fmt011-pos Duplicates.lean   "FMT011" --select FMT011
expect_codes fmt012-pos DevOption.lean    "FMT012" --select FMT012
expect_codes fmt013-pos NestedParen.lean  "FMT013" --select FMT013

# The three fixable rules carry a `.safe` fix whose edits are expressed in original-source
# coordinates (`Application.renderCanonicalText` docstring). Pin the applicability and the byte spans
# the edits delete: FMT010/011 drop the duplicate instance and its `", "` separator; FMT013 deletes
# just the outer parenthesis pair and leaves the inner `(1)`.
python3 - "$work/fmt010-pos.json" "$work/fmt011-pos.json" "$work/fmt013-pos.json" <<'PY'
import json, sys
def fix(path):
    data = json.load(open(path))
    finding, = data["files"][0]["findings"]
    return finding["fix"]
fmt010, fmt011, fmt013 = (fix(p) for p in sys.argv[1:4])
assert fmt010["applicability"] == "safe", fmt010
assert [(e["range"]["start"], e["range"]["stop"], e["replacement"]) for e in fmt010["edits"]] \
    == [(42, 48, "")], fmt010
assert fmt011["applicability"] == "safe", fmt011
assert [(e["range"]["start"], e["range"]["stop"], e["replacement"]) for e in fmt011["edits"]] \
    == [(110, 116, "")], fmt011
assert fmt013["applicability"] == "safe", fmt013
assert [(e["range"]["start"], e["range"]["stop"], e["replacement"]) for e in fmt013["edits"]] \
    == [(51, 52, ""), (55, 56, "")], fmt013
PY

# --- Negative: a clean file trips none of the six --------------------------------------------------
expect_codes clean Clean.lean "" "${all_six[@]}"

# --- Near-misses: each rule's documented exclusion (catalog 01 §5) stays silent under all six ------
# FMT008: a module with no `declaration` node (a section-only re-export/config module) is not undoc.
expect_codes near-008 NearNoDecl.lean     "" "${all_six[@]}"
# FMT009: an outermost `noncomputable section` left open is the whole-file idiom, not an unclosed one.
expect_codes near-009 NearOpenSection.lean "" "${all_six[@]}"
# FMT010: `@[local simp, simp]` differs by `attrKind`; comparison is byte-exact, so no duplicate.
expect_codes near-010 NearAttr.lean       "" "${all_six[@]}"
# FMT011: `deriving Repr, BEq` are distinct classes, not a repeat.
expect_codes near-011 NearDeriving.lean   "" "${all_six[@]}"
# FMT012: `set_option maxHeartbeats` is a proof-scaling knob, outside the four debug roots.
expect_codes near-012 NearOption.lean     "" "${all_six[@]}"
# FMT013: a tuple `(1, 2)`, a type ascription `(1 : Nat)`, and a cdot `(· + 1)` are each a distinct
# node kind, none a `paren` wrapping a `paren`.
expect_codes near-013 NearParen.lean      "" "${all_six[@]}"

# --- Quotation / generated syntax: a defect *inside* `` `(…) `` is data, not code, and must not fire.
# `macro "myone" : term => `(((1)))` has a nested paren; `mydef` quotes `@[simp, simp]`.
expect_codes quote-paren QuoteParen.lean "" "${all_six[@]}"
expect_codes quote-attr  QuoteAttr.lean  "" "${all_six[@]}"

# --- Custom syntax reusing `(`: a `syntax "wrap(" term ")"` declaration is preserved and ignored. ---
expect_codes custom-syntax CustomSyntax.lean "" "${all_six[@]}"

# --- Malformed input: an unparseable file is `broken`, reported without a crash and without a false
# finding. A syntax rule needs a projection; a file that does not parse has none.
run_expect 1 "$work/malformed.json" \
  sfmt check --root . --json --no-cache "${all_six[@]}" tests/syntax/Malformed.lean
python3 - "$work/malformed.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["broken"] == 1, data
assert data["findings"] == 0, data
assert data["infrastructureFailures"] == [], data
assert data["files"][0]["status"] == "broken", data["files"][0]
PY

# --- Fix deferral: `fix` renders canonical text and runs only source rules, so a syntax-tier fix is
# reported by `check` but neither applied nor withheld by `fix` (Application.renderCanonicalText:
# `ruff-06`'s RFX-SPEC owns canonical-coordinate syntax fixing). Pin the current limit: the file is
# left byte-identical and nothing is written.
cp -p tests/syntax/NestedParen.lean "$work/NestedParen.lean"
run_expect 0 "$work/fix-deferral.json" \
  sfmt fix --root . --json --no-cache --select FMT013 tests/syntax/NestedParen.lean
cmp tests/syntax/NestedParen.lean "$work/NestedParen.lean"
python3 - "$work/fix-deferral.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["written"] == 0 and data["changed"] == 0, data
report = data["files"][0]
# The finding is still surfaced -- `check`'s report is honest -- but the patch left the file alone.
assert [f["code"] for f in report["findings"]] == ["FMT013"], report
assert report["written"] is False and report["status"] == "clean", report
PY

echo "lean-fmt syntax-tier rule integration tests passed"
