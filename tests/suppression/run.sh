#!/usr/bin/env bash
set -euo pipefail

# End-to-end acceptance for the source-suppression layer (`RSP-FINAL`). Where `LeanFmtTest.lean`'s
# `testSuppression` checks `apply`/`collect` against a hand-built projection, this drives the real CLI
# over committed fixtures parsed by the real frontend: the acceptance matrix from
# `docs/projects/ruff-07-suppressions/prompts/03-acceptance.md` — nested syntax, doc comments, custom
# commands, formatting movement, unknown rules, per-file config, and unused fixes.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
cache_root="$repo_root/.lean-fmt-cache"
# `fix` mutates in place and needs the file inside the lake project (a toolchain at the root), so the
# movement scratch copy lives in the repo, not in `$work`. It is untracked and invisible to the
# printer corpus (`git ls-files 'LeanFmt/*.lean'`); the trap removes it.
scratch="$repo_root/tests/suppression/.movement-scratch.lean"
trap 'rm -rf "$work" "$cache_root" "$scratch"' EXIT

cd "$repo_root"
rm -rf "$cache_root"
LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

run_expect() {
  local expected=$1 output=$2
  shift 2
  set +e
  "$@" >"$output" 2>"$output.stderr"
  local actual=$?
  set -e
  if [[ $actual -ne $expected ]]; then
    printf 'expected exit %s, got %s from: %s\n' "$expected" "$actual" "$*" >&2
    cat "$output" "$output.stderr" >&2
    exit 1
  fi
}

# A committed fixture must stay canonical, so `git diff --check` and the printer agree the fixtures
# need no reformatting beyond the deliberate rule violation each carries (a duplicate import, a
# redundant paren). Nothing to do here beyond the assertions below; the fixtures are checked in exactly
# as the suite reads them.

# --- Doc comments and module docstrings are tokens, not comments: directive text in them is inert. ---
# The RSP-SPEC stop rule ("a directive is a comment, nothing else"), over the real parser. The FMT005
# duplicate-import finding must still report; suppressed stays 0.
run_expect 1 "$work/doc.json" "$application" check --root . --json --no-cache \
  tests/suppression/DocComment.lean
python3 - "$work/doc.json" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
codes = [f["code"] for f in file["findings"]]
assert "FMT005" in codes, f"a docstring silenced a real finding: {codes}"
assert not any(c in ("FMT900", "FMT901") for c in codes), f"docstring text parsed as a directive: {codes}"
assert file["suppressed"] == 0, f"a docstring suppressed something: {file['suppressed']}"
PY

# --- Nested syntax: ignore-next inside a namespace suppresses the inner finding. The finding is a
#     redundant nested paren (FMT013, a syntax rule opted into with `--select`), since after RDF-LAYOUT
#     no default finding lands on a `def` inside a namespace — the retired FMT001 used to. ---
run_expect 0 "$work/nested.json" "$application" check --root . --json --no-cache \
  --select FMT013 tests/suppression/Nested.lean
python3 - "$work/nested.json" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
assert file["findings"] == [], f"a nested ignore-next did not suppress: {file['findings']}"
assert file["suppressed"] == 1, f"nested suppression miscounted: {file['suppressed']}"
PY

# --- Custom command: file-local syntax + macro. ignore-file suppresses, and the custom command
#     round-trips (format leaves the greet command's bytes alone). ---
run_expect 0 "$work/custom.json" "$application" check --root . --json --no-cache \
  tests/suppression/Custom.lean
python3 - "$work/custom.json" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
assert file["findings"] == [], f"ignore-file left a finding on a custom command: {file['findings']}"
assert file["suppressed"] >= 1, f"custom-command suppression miscounted: {file['suppressed']}"
PY

# --- Formatting movement + the round-trip invariant. `fix` reflows the ignore-next item, collapsing
#     its non-canonical `namespace     Beta` spacing to a single space (a movement the printer owns, as
#     `tests/modes` proves on `Layout.lean`). The ignore-next covers a namespace with no finding, so it
#     is an honest FMT900 throughout. What this pins is the movement: through the byte shift the
#     directive comment round-trips exactly once. (Before RDF-LAYOUT this fixture used a trailing-space
#     item and FMT001; the retired rule's whitespace behavior is now the reflow's, and the reflow only
#     owns whitespace it lays down — not the bytes of a verbatim command body — so the item moved to a
#     spacing the printer actually normalizes.) ---
cp tests/suppression/Movement.lean "$scratch"
before_directives=$(grep -c 'lean-fmt: ignore-next' "$scratch")
test "$before_directives" = 1
run_expect 0 "$work/move-fix.txt" "$application" fix --root . --no-cache "$scratch"
after_directives=$(grep -c 'lean-fmt: ignore-next' "$scratch")
test "$after_directives" = 1 || { echo "the directive comment did not round-trip exactly once" >&2; exit 1; }
grep -q '^namespace Beta$' "$scratch" || { echo "fix did not reflow the item" >&2; exit 1; }
# After the finding is gone the directive is unused: check reports FMT900, and a second fix is a no-op.
run_expect 1 "$work/move-recheck.json" "$application" check --root . --json --no-cache \
  "$scratch"
python3 - "$work/move-recheck.json" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
codes = [f["code"] for f in file["findings"]]
assert codes == ["FMT900"], f"post-fix directive is not a lone unused-directive report: {codes}"
PY
# fix exits 0: it reformatted successfully. The residual FMT900 is a lint diagnostic fix cannot remove
# (it preserves comments), so it does not fail the format run — the lint-vs-format split (`check`
# above still exits 1 on it). The idempotence claim is the byte result: nothing more to write.
run_expect 0 "$work/move-idempotent.txt" "$application" fix --root . --no-cache "$scratch"
grep -q 'written=0' "$work/move-idempotent.txt" || { echo "fix was not idempotent" >&2; exit 1; }
# Batch fix does not auto-remove the unused directive (decision 2): it stays after a second fix.
test "$(grep -c 'lean-fmt: ignore-next' "$scratch")" = 1

# --- Unused fixes. A blanket ignore over a clean file is FMT900 with a *safe* removal fix whose edit
#     deletes exactly the directive line and its newline — the editor code-action, never batch fix. ---
run_expect 1 "$work/unused.json" "$application" check --root . --json --no-cache \
  tests/suppression/Unused.lean
python3 - "$work/unused.json" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
find, = file["findings"]
assert find["code"] == "FMT900", f"a blanket ignore over a clean file is not FMT900: {find['code']}"
fix = find["fix"]
assert fix["applicability"] == "safe", f"the removal fix is not safe: {fix['applicability']}"
edit, = fix["edits"]
src = open("tests/suppression/Unused.lean", "rb").read()
cut = src[:edit["range"]["start"]] + edit["replacement"].encode() + src[edit["range"]["stop"]:]
assert cut == b"module\n\ndef unusedValue : Nat := 1\n", f"removal fix left a mess: {cut!r}"
PY

# --- Malformed directive: an unknown verb is FMT901 [display-only], reported never dropped. ---
run_expect 1 "$work/malformed.json" "$application" check --root . --json --no-cache \
  tests/suppression/Malformed.lean
python3 - "$work/malformed.json" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
find, = [f for f in file["findings"] if f["code"] == "FMT901"]
assert find["fix"]["applicability"] == "display-only", f"FMT901 is not display-only: {find['fix']}"
assert "ignor" in find["message"], f"FMT901 did not name the bad verb: {find['message']}"
PY

# --- Per-file config composition. The config already ignores FMT005 for this glob, so the trailing
#     directive naming FMT005 suppresses nothing and is itself unused: the RUF100 analog composes with
#     config. ---
run_expect 1 "$work/perfile.json" "$application" check --root . --json --no-cache \
  --config tests/suppression/lean-fmt.toml tests/suppression/PerFile.lean
python3 - "$work/perfile.json" <<'PY'
import json, sys
file, = json.load(open(sys.argv[1]))["files"]
codes = [f["code"] for f in file["findings"]]
assert codes == ["FMT900"], f"a config-redundant directive is not the lone FMT900: {codes}"
assert file["suppressed"] == 0, f"a config-dropped rule was counted as suppressed: {file['suppressed']}"
PY

printf 'lean-fmt suppression acceptance tests passed\n'
