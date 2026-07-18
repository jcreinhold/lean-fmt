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
# `fix` writes in place and only operates on files under the project root, so the apply-and-verify
# cases below run on in-tree probe copies; the trap removes them even if a case fails mid-run.
trap 'rm -rf "$work" "$cache_root" "$repo_root"/tests/syntax/.ryc-fix-*.lean' EXIT

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
# FMT012 (RYR-FINAL scope decision): the inline `set_option pp.all true in <decl>` scoped form is the
# same `set_option` command node, so a committed dev option fires whether standalone or `… in`-scoped.
# Report-only, so the scoped boundary raises no byte-safety question -- reporting both is uniform.
expect_codes fmt012-scoped-in ScopedInOption.lean "FMT012" --select FMT012
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
# FMT009 regression (RYR-FINAL frozen-sample false positive): one `end Alpha.Beta` closes both a
# `namespace Alpha` and a `namespace Beta` -- the name stack must pop the group the dotted name spells,
# not one scope per `end`. `ScopesBalanced` adds a dotted namespace and a named section closed normally.
expect_codes near-009-dotted EndDotted.lean      "" "${all_six[@]}"
expect_codes near-009-nested ScopesBalanced.lean "" "${all_six[@]}"
# FMT010: `@[local simp, simp]` differs by `attrKind`; comparison is byte-exact, so no duplicate.
expect_codes near-010 NearAttr.lean       "" "${all_six[@]}"
# FMT011: `deriving Repr, BEq` are distinct classes, not a repeat.
expect_codes near-011 NearDeriving.lean   "" "${all_six[@]}"
# FMT012: `set_option maxHeartbeats` is a proof-scaling knob, outside the four debug roots.
expect_codes near-012 NearOption.lean     "" "${all_six[@]}"
# FMT013: a tuple `(1, 2)`, a type ascription `(1 : Nat)`, and a cdot `(· + 1)` are each a distinct
# node kind, none a `paren` wrapping a `paren`.
expect_codes near-013 NearParen.lean      "" "${all_six[@]}"

# --- Comments: a defect named only inside a line or block comment is trivia, absent from the leaf
# walk, and must not fire. `Comment.lean` buries a dev `set_option`, a redundant `((paren))`, a
# duplicate `@[simp, simp]`, and a stray `end` in comments; all six stay silent.
expect_codes comment Comment.lean "" "${all_six[@]}"

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

# --- Fix application (RYC-IMPL): a syntax-tier `.safe` fix is now *applied* by `fix`, composed by
# re-projecting the canonical text so its edits land in canonical coordinates (Application:
# `reprojectCanonical`; ruff-10b RYC-SPEC `notes/01-model.md`). For each fixable rule, assert `fix`
# writes the corrected bytes (the defect gone, the intended form present) and that a re-`check` of the
# written file reports nothing for that rule -- the fix is idempotent.
fix_applies() {
  local label=$1 fixture=$2 selector=$3 gone=$4 present=$5
  local probe="tests/syntax/.ryc-fix-$label.lean"
  cp "tests/syntax/$fixture" "$probe"
  run_expect 0 "$work/$label-fix.json" \
    sfmt fix --root . --json --no-cache --select "$selector" "$probe"
  GONE="$gone" PRESENT="$present" PROBE="$probe" LABEL="$label" python3 - "$work/$label-fix.json" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
label = os.environ["LABEL"]
assert data["written"] == 1 and data["changed"] == 1, (label, data)
report = data["files"][0]
assert report["status"] == "fixed" and report["written"] is True, (label, report)
got = open(os.environ["PROBE"]).read()
assert os.environ["GONE"] not in got, (label, "defect still present", repr(got))
assert os.environ["PRESENT"] in got, (label, "fixed form absent", repr(got))
PY
  run_expect 0 "$work/$label-recheck.json" \
    sfmt check --root . --json --no-cache --select "$selector" "$probe"
  LABEL="$label" python3 - "$work/$label-recheck.json" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
assert data["findings"] == 0, (os.environ["LABEL"], "not idempotent", data)
PY
  rm -f "$probe"
}

# FMT013 deletes the outer pair (`((1))` -> `(1)`); FMT010/011 drop the duplicate `simp` / `Repr`.
fix_applies fmt013 NestedParen.lean FMT013 '((1))' '(1)'
fix_applies fmt010 Duplicates.lean  FMT010 '@[simp, simp]' '@[simp]'
fix_applies fmt011 Duplicates.lean  FMT011 'deriving Repr, Repr' 'deriving Repr'

# --- RYC-FINAL adversarial composition cases -----------------------------------------------------
# UTF-8 boundary: the fix range abuts a multibyte glyph (`ϕ`, 2 bytes). Every compiler-produced offset
# indexes the normalized bytes, so dropping the outer parens of `((ϕ))` must land on the `(`/`)`
# boundaries and leave `ϕ` intact. This is the frozen-sample `((ϕ i x))` shape (NoncommPiCoprod) in a
# writable miniature.
fix_applies fmt013-utf8 NestedParenUtf8.lean FMT013 '((' '(ϕ)'

# Multi-edit over nested defects: `(((1)))` yields two FMT013 findings whose point-deletions are
# distinct bytes; they compose in one transaction to `(1)` with no false conflict.
fix_applies fmt013-triple NestedParenTriple.lean FMT013 '((' '(1)'

# Token-mover: an earlier source-shifting fix (FMT010 drops `, simp`, and the attribute reflows onto
# its own line) moves the later FMT013 paren defect to a new canonical offset. Because every edit is
# derived from one re-projected canonical model and applied as one transaction, the paren fix still
# lands exactly -- translating the original-coordinate edit onto the moved bytes would corrupt here.
probe="tests/syntax/.ryc-fix-mover.lean"
cp tests/syntax/AttrThenParen.lean "$probe"
run_expect 0 "$work/mover-fix.json" \
  sfmt fix --root . --json --no-cache --select FMT010 --select FMT013 "$probe"
PROBE="$probe" python3 - "$work/mover-fix.json" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
assert data["written"] == 1 and data["changed"] == 1, data
got = open(os.environ["PROBE"]).read()
assert "((" not in got and ", simp" not in got, ("mover not fully composed", repr(got))
assert "(1)" in got and "@[simp]" in got, ("mover lost a fix", repr(got))
PY
# Idempotence: a second `fix` on the written file is a no-op -- nothing is left to change.
run_expect 0 "$work/mover-refix.json" \
  sfmt fix --root . --json --no-cache --select FMT010 --select FMT013 "$probe"
python3 - "$work/mover-refix.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["written"] == 0 and data["changed"] == 0, ("second fix was not a no-op", data)
assert data["files"][0]["status"] == "clean", data["files"][0]
PY
rm -f "$probe"

# Pass-order independence: the composed output does not depend on `--select` order. The same two rules
# selected in either order write byte-identical results, because the edits live in one coordinate
# system and one atomic transaction rather than a sequence of re-derived passes.
order_a="tests/syntax/.ryc-fix-ordera.lean"
order_b="tests/syntax/.ryc-fix-orderb.lean"
cp tests/syntax/AttrThenParen.lean "$order_a"
cp tests/syntax/AttrThenParen.lean "$order_b"
run_expect 0 "$work/order-a.json" \
  sfmt fix --root . --json --no-cache --select FMT010 --select FMT013 "$order_a"
run_expect 0 "$work/order-b.json" \
  sfmt fix --root . --json --no-cache --select FMT013 --select FMT010 "$order_b"
cmp "$order_a" "$order_b" || { echo "pass-order changed the composed bytes" >&2; exit 1; }
rm -f "$order_a" "$order_b"

echo "lean-fmt syntax-tier rule integration tests passed"
