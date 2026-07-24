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
syntax = json.load(open(sys.argv[1]))["artifact"]["syntaxData"]
assert "choice" in syntax["kinds"], "the ambiguous parse produced no choice node; case is vacuous"
PY

# The oracle must be able to fail. Each mutation is a lie a corrupt or buggy producer could tell,
# and a validator that accepts any of them proves nothing about the ones it accepted above.
#
# The tiling mutations are the load-bearing ones. `ModuleSyntax.structurallyValid` accepts every one
# of them: it checks that roots are contiguous in the entry array and that command ranges lie in the
# file, and never that one leaf's `trailingStop` is the next leaf's `leadingStart`. A producer that
# drops a token's bytes or claims the same bytes twice is structurally valid and still wrong.
project "$work/borrowed.setup.json" "$work/unicode.lean" unicode.lean "$work/mutate-base.json"
python3 - "$work/mutate-base.json" "$work/unicode.lean" "$work/choice.json" "$work/choice.lean" \
  "$oracle" <<'PY'
import copy, json, subprocess, sys, tempfile, os

base = json.load(open(sys.argv[1]))["artifact"]
source_path = sys.argv[2]
choice_base = json.load(open(sys.argv[3]))["artifact"]
choice_path = sys.argv[4]
oracle = sys.argv[5]

ENTRY_MISSING, ENTRY_NODE, ENTRY_ATOM, ENTRY_IDENT = 0, 1, 2, 3


def mutate(name, edit, artifact=None, path=None):
    artifact = copy.deepcopy(artifact if artifact is not None else base)
    edit(artifact)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(artifact, handle)
        temp = handle.name
    try:
        done = subprocess.run([sys.executable, oracle, temp, path or source_path],
                              capture_output=True, text=True)
    finally:
        os.unlink(temp)
    assert done.returncode != 0, f"the oracle accepted a {name} mutation; it has no teeth"
    return f"{name}: {done.stderr.strip()}"


def leaves(syntax):
    """Array positions of the original-info leaves, in pre-order (which is array order)."""
    found = [index for index, entry in enumerate(syntax["entries"])
             if entry[0] in (ENTRY_ATOM, ENTRY_IDENT) and isinstance(entry[1], list)]
    assert len(found) >= 4, f"the mutation base has only {len(found)} leaves"
    return found


def leaf(syntax, position):
    return syntax["entries"][leaves(syntax)[position]]


def trailing_leaf(syntax):
    """The first leaf that owns trailing trivia. Shrinking one of those opens a hole; shrinking a
    leaf with none would instead invert `endPosition <= trailingStop` and be caught as bad order,
    which is a different claim than the one this mutation means to test."""
    for index in leaves(syntax):
        info = syntax["entries"][index][1]
        if info[4] > info[3]:
            return syntax["entries"][index]
    raise AssertionError("no leaf in the mutation base owns trailing trivia")


def shift(info, field, delta):
    info[field] += delta


def choice_alternative(syntax):
    """Entry positions of the leaves under the second alternative of the first choice node."""
    kinds, entries = syntax["kinds"], syntax["entries"]
    choice_kind = kinds.index("choice")

    def subtree(index):
        """Return (next entry index, [leaf entry positions in this subtree])."""
        entry = entries[index]
        if entry[0] == ENTRY_MISSING:
            return index + 1, []
        if entry[0] != ENTRY_NODE:
            return index + 1, [index]
        cursor, found = index + 1, []
        for _ in range(entry[3]):
            cursor, child = subtree(cursor)
            found.extend(child)
        return cursor, found

    for index, entry in enumerate(entries):
        if entry[0] == ENTRY_NODE and entry[2] == choice_kind:
            cursor, alternatives = index + 1, []
            for _ in range(entry[3]):
                cursor, child = subtree(cursor)
                alternatives.append(child)
            assert len(alternatives) >= 2, "the choice node has one alternative; case is vacuous"
            assert alternatives[1], "the choice node's second alternative holds no leaf"
            return alternatives[1]
    raise AssertionError("no choice node in the choice fixture")


# `s` is the artifact; `x` its projection. Identity lives on the artifact, structure on the
# projection, and the tiling claims live on individual leaves.
def sd(edit):
    return lambda s: edit(s["syntaxData"])


checks = [
    # Identity: the artifact must be about the file the consumer holds, not another one.
    ("wrong digest", lambda s: s.update(normalizedDigest="0" * 64)),
    ("wrong length", lambda s: s.update(normalizedBytes=s["normalizedBytes"] + 1)),
    ("stale schema", lambda s: s.update(schema="lean-fmt.module-artifact.v0")),
    ("carries findings", lambda s: s.update(findings=[])),
    # Roots: the command array must be a concatenation of whole trees with nothing between them.
    ("non-contiguous root", sd(lambda x: x["commands"][0].update(entry=1))),
    ("dangling options ref",
     sd(lambda x: x["commands"][0].update(options=len(x["options"])))),
    ("command range past end",
     sd(lambda x: x["commands"][0]["range"].update(stop=x["commands"][0]["range"]["stop"] + 10**9))),
    ("terminal misplaced", sd(lambda x: x.update(terminal=x["terminal"] + 1))),
    ("truncated entries", sd(lambda x: x["entries"].pop())),
    ("trailing entry", sd(lambda x: x["entries"].append([ENTRY_MISSING]))),
    # Tiling: a hole, an overlap, and a dropped leaf are all silent losses of source, and all three
    # are invisible to `structurallyValid`.
    ("dropped leaf",
     sd(lambda x: x["entries"].__setitem__(leaves(x)[2], [ENTRY_MISSING]))),
    ("hole after leaf", sd(lambda x: shift(trailing_leaf(x)[1], 4, -1))),
    ("overlapping leaf", sd(lambda x: shift(trailing_leaf(x)[1], 4, 1))),
    ("leaf past end", sd(lambda x: shift(leaf(x, -1)[1], 4, 10**6))),
    ("inverted leaf", sd(lambda x: shift(leaf(x, 2)[1], 2, 10**9))),
    # Provenance: a fabricated position is not a projection of anything.
    ("synthetic leaf",
     sd(lambda x: leaf(x, 2).__setitem__(1, [2, leaf(x, 2)[1][2], leaf(x, 2)[1][3], True]))),
    # Dangling references.
    ("bad kind ref", sd(lambda x: x["entries"][0].__setitem__(2, len(x["kinds"])))),
]
for name, edit in checks:
    print("   rejected", mutate(name, edit))

# `choice` alternatives all spell one byte range. Four walks in `NativeLayout.lean` take
# `children[0]`; `NativeLayout.command` gates them by comparing every alternative's terminal
# sequence, and this oracle checks the same property over the projected artifact independently of
# that gate -- so it must be able to see them disagree.
def disagree(artifact):
    syntax = artifact["syntaxData"]
    position = choice_alternative(syntax)[0]
    # `trailingStop`, so the span the oracle compares differs while the info stays well ordered and
    # the failure is attributable to disagreement rather than to a malformed leaf.
    shift(syntax["entries"][position][1], 4, 1)


print("   rejected", mutate("choice disagreement", disagree, choice_base, choice_path))
print(f"the oracle rejected all {len(checks) + 1} mutations")
PY

printf 'lean-fmt lossless projection corpus passed\n'
