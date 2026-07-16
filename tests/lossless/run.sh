#!/usr/bin/env bash
set -euo pipefail

# Round-trip and differential corpus for the lossless projection.
#
# The corpus is this repository's own Lean modules. They are real, non-trivial, always present, and
# they change as the project changes, which a frozen fixture cannot. Production `LeanFmt/*` modules
# cannot carry the plugin without depending on themselves, so the exact frontend is the only path
# for them; `tests/check/run.sh` is what proves the two producers agree.
#
# Every claim is re-derived by `check_projection.py`, which shares no code with the product and can
# therefore contradict it. The mutation section below is what makes that non-vacuous.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

oracle=tests/lossless/check_projection.py

# `__analyze-exact SETUP SOURCE DISPLAY MAX_BYTES` takes the source path separately from the setup,
# so a generated file can borrow a declared module's setup. Byte-exotic fixtures are generated
# rather than committed: git normalizes line endings, so a CRLF fixture cannot survive as a file.
LEAN_NUM_THREADS=1 lake setup-file tests/check/Clean.lean >"$work/borrowed.setup.json"

project() {
  local setup=$1 source=$2 display=$3 out=$4
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$setup" "$source" "$display" 8589934592 >"$out"
}

# The repository's own modules, largest last so a regression surfaces on the small ones first.
modules=$(find LeanFmt -name '*.lean' | LC_ALL=C sort)
for module in $modules LeanFmtTest.lean Main.lean; do
  LEAN_NUM_THREADS=1 lake setup-file "$module" >"$work/setup.json"
  project "$work/setup.json" "$module" "$module" "$work/envelope.json"
  python3 - "$work/envelope.json" "$module" <<'PY'
import json, sys
envelope = json.load(open(sys.argv[1]))
assert not envelope["diagnostics"], f"{sys.argv[2]} did not analyze: {envelope['diagnostics']}"
assert envelope["artifact"], f"{sys.argv[2]} produced no artifact"
PY
  printf '%-32s ' "$module"
  python3 "$oracle" --envelope "$work/envelope.json" "$module"
done

# Byte-exotic sources. Each is a case the projection's coordinate system or boundaries must survive,
# and each was a real defect at some point in this stack's history.
exotic_case() {
  local name=$1
  printf '%-32s ' "exotic:$name"
  project "$work/borrowed.setup.json" "$work/$name.lean" "$name.lean" "$work/$name.json"
  python3 "$oracle" --envelope "$work/$name.json" "$work/$name.lean"
}

# CRLF: every compiler offset indexes `raw.crlfToLf`, so the oracle's digest of the *normalized*
# bytes must match while `raw_bytes` exceeds `normalized_bytes`.
printf 'module\r\n\r\ndef crlfValue : Nat := 1\r\n-- a comment\r\n' >"$work/crlf.lean"
exotic_case crlf

# `#exit` leaves a tail Lean never parses. `terminalStop` is where the token stream ends, so the
# tail must reconstruct verbatim rather than being claimed by a token that does not cover it.
printf 'module\n\ndef exitValue : Nat := 1\n#exit\nthis tail is never parsed {{{\n' >"$work/exit.lean"
exotic_case exit

# The same, in CRLF, so the tail crosses the normalization boundary too.
printf 'module\r\n\r\ndef bothValue : Nat := 1\r\n#exit\r\nunparsed CRLF tail\r\n' >"$work/exitcrlf.lean"
exotic_case exitcrlf

# No final newline: the last token's trailing trivia ends exactly at end of file.
printf 'module\n\ndef noFinalNewline : Nat := 1' >"$work/nonewline.lean"
exotic_case nonewline

# Nothing but a header: the whole file is header, and the token stream is empty.
printf 'module\n' >"$work/headeronly.lean"
exotic_case headeronly

# Trailing trivia is greedy up to the next token's text, so comments after the last command are
# absorbed by its trailing rather than stranded before `eoi`.
printf 'module\n\ndef beforeComments : Nat := 1\n\n-- after the last command\n/- and a block -/\n' \
  >"$work/eofcomments.lean"
exotic_case eofcomments

# Multi-byte UTF-8 must be counted in bytes, not codepoints, everywhere.
printf 'module\n\ndef «π ≤ τ» : String := "λ → ∀ 🎉"\n-- ∀ε>0 ∃δ>0\n' >"$work/unicode.lean"
exotic_case unicode

# A `choice` node holds several parses of one byte range; only one may spell those bytes.
printf 'module\n\nstructure P where\n  a : Nat\n  b : Nat\n\ndef mk (a b : Nat) : P := { a, b }\n' \
  >"$work/choice.lean"
exotic_case choice
python3 - "$work/choice.json" <<'PY'
import json, sys
source = json.load(open(sys.argv[1]))["artifact"]["source"]
assert "choice" in source["kinds"], "the ambiguous parse produced no choice node; case is vacuous"
PY

# The oracle must be able to fail. Each mutation is a lie a corrupt or buggy producer could tell,
# and a validator that accepts any of them proves nothing about the ones it accepted above.
project "$work/borrowed.setup.json" "$work/unicode.lean" unicode.lean "$work/mutate-base.json"
python3 - "$work/mutate-base.json" "$work/unicode.lean" "$oracle" <<'PY'
import copy, json, subprocess, sys, tempfile, os

base = json.load(open(sys.argv[1]))["artifact"]
source_path, oracle = sys.argv[2], sys.argv[3]


def mutate(name, edit):
    artifact = copy.deepcopy(base)
    edit(artifact["source"])
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(artifact, handle)
        path = handle.name
    try:
        done = subprocess.run([sys.executable, oracle, path, source_path],
                              capture_output=True, text=True)
    finally:
        os.unlink(path)
    assert done.returncode != 0, f"the oracle accepted a {name} mutation; it has no teeth"
    return f"{name}: {done.stderr.strip()}"


def bump(source, key):
    source[key] += 1


checks = [
    # Identity: the artifact must be about the file the consumer holds, not another one.
    ("wrong digest", lambda s: s.update(normalizedDigest="0" * 64)),
    ("wrong length", lambda s: bump(s, "normalizedBytes")),
    # Boundaries.
    ("header past terminal", lambda s: s.update(headerStop=s["terminalStop"] + 1)),
    ("terminal past end", lambda s: bump(s, "terminalStop")),
    ("short terminal", lambda s: s.update(terminalStop=s["terminalStop"] - 1)),
    # Tiling: a hole, an overlap, and a dropped token are all silent losses of source.
    ("dropped token", lambda s: s["tokens"].pop()),
    ("shifted token", lambda s: s["tokens"][0].__setitem__(2, s["tokens"][0][2] + 1)),
    ("trivia hole", lambda s: s["tokens"][0][5].__setitem__(
        -1, [s["tokens"][0][5][-1][0], s["tokens"][0][5][-1][1] - 1])),
    # Content: the spans can tile perfectly while every run is misdescribed.
    ("misclassified trivia", lambda s: s["tokens"][0][5][0].__setitem__(0, 1)),
    # Provenance: a fabricated position is not a projection of anything.
    ("synthetic leaf", lambda s: s["tokens"][0].__setitem__(3, 1)),
    # Dangling references.
    ("bad node ref", lambda s: s["tokens"][0].__setitem__(0, len(s["nodes"]))),
    ("bad kind ref", lambda s: s["nodes"][0].__setitem__(0, len(s["kinds"]))),
    ("stale schema", lambda s: s.update(schema="lean-fmt.lossless-source.v0")),
]
for name, edit in checks:
    print("   rejected", mutate(name, edit))
print(f"the oracle rejected all {len(checks)} mutations")
PY

printf 'lean-fmt lossless projection corpus passed\n'
