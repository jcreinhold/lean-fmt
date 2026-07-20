#!/usr/bin/env bash
set -euo pipefail

# Characterization suite for the platform behaviors `ruff-16` RWI-SPEC froze
# (`docs/projects/ruff-16-watch-incremental/notes/01-watch-generations.md`).
#
# RWI-SPEC ships no production surface, so this suite deliberately tests **git and the filesystem**,
# not `lean-fmt`. Every assertion below is a premise the RWI-IMPL selection adapter is built on. If a
# future git changes one of them, the adapter is silently wrong; this suite makes it fail loudly
# instead. RWI-IMPL extends this file with the `lean-fmt` surface itself.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { printf 'tests/watch: %s\n' "$1" >&2; exit 1; }

expect_eq() {
  local what=$1 expected=$2 actual=$3
  if [[ "$expected" != "$actual" ]]; then
    printf 'tests/watch: %s\n  expected: %s\n  actual:   %s\n' "$what" "$expected" "$actual" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# §2 mtime carries populated nanoseconds, and distinguishes a same-size rewrite.
#
# The whole poll design rests on this. A filesystem or Lean binding that truncated to whole seconds
# would make `(size, mtime)` blind to a fast edit, and §2's "detection latency is bounded" claim would
# have to become something weaker.
# ---------------------------------------------------------------------------
probe="$work/mtime-probe.txt"
printf 'AAAA' >"$probe"
first_ns=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$probe")
printf 'BBBB' >"$probe"
second_ns=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$probe")
first_size=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_size)' "$probe")

if [[ "$first_ns" == "$second_ns" ]]; then
  fail "same-size rewrite produced an identical mtime ($first_ns); RWI-SPEC §2 assumed sub-second granularity"
fi
expect_eq "same-size rewrite kept its size (that is the point)" "4" "$first_size"

# ---------------------------------------------------------------------------
# Build the fixture repository used by the git assertions.
# ---------------------------------------------------------------------------
fixture="$work/repo"
mkdir -p "$fixture/sub"
cd "$fixture"
git init -q -b main .
git config user.email lean-fmt@example.invalid
git config user.name 'lean-fmt tests'

printf 'a\n' >A.lean
printf 'b\n' >sub/B.lean
printf 'c\n' >C.lean
git add -A
git commit -qm base

# A rename, a delete, a modification, an untracked file, and an ignored file.
git mv A.lean Renamed.lean
printf 'b2\n' >>sub/B.lean
git rm -q C.lean
printf 'n\n' >New.lean
printf 'ig\n' >Ignored.lean
printf 'Ignored.lean\n' >.gitignore

# ---------------------------------------------------------------------------
# §9.4 `git diff` never reports untracked files.
#
# This is the assertion that protects users from the worst failure mode of a `--changed` mode built
# on `diff` alone: brand-new files silently skipped.
# ---------------------------------------------------------------------------
if git diff --name-status HEAD | grep -q 'New\.lean'; then
  fail "git diff reported an untracked file; RWI-SPEC §9.4 unions ls-files precisely because it does not"
fi
if ! git ls-files --others --exclude-standard | grep -q '^New\.lean$'; then
  fail "git ls-files --others did not report the untracked New.lean"
fi

# §9.4 `--exclude-standard` honours .gitignore.
if git ls-files --others --exclude-standard | grep -q '^Ignored\.lean$'; then
  fail "git ls-files --others --exclude-standard leaked an ignored file"
fi

# ---------------------------------------------------------------------------
# §9.2/§9.3 The `-z` stream: rename records carry three fields, everything else two.
#
# A parser that assumes pairs desynchronizes on the first rename and mis-assigns every path after it.
# ---------------------------------------------------------------------------
# `mapfile -d ''` would be the natural reader, but macOS ships bash 3.2 and it is a bash 4 builtin.
# Read NUL-terminated fields portably instead.
fields=()
while IFS= read -r -d '' field; do
  fields[${#fields[@]}]="$field"
done < <(git diff --name-status -z HEAD)

[[ ${#fields[@]} -gt 0 ]] || fail "git diff -z produced no fields for the fixture"

rename_index=-1
delete_index=-1
i=0
while [[ $i -lt ${#fields[@]} ]]; do
  case "${fields[$i]}" in
    R*) [[ $rename_index -lt 0 ]] && rename_index=$i ;;
    D)  [[ $delete_index -lt 0 ]] && delete_index=$i ;;
  esac
  i=$((i + 1))
done

[[ $rename_index -ge 0 ]] || fail "fixture produced no rename record"
expect_eq "-z rename old path" "A.lean" "${fields[$((rename_index + 1))]}"
expect_eq "-z rename new path" "Renamed.lean" "${fields[$((rename_index + 2))]}"

# The delete is a two-field record: status then path, with no second path.
[[ $delete_index -ge 0 ]] || fail "fixture produced no delete record"
expect_eq "-z delete path" "C.lean" "${fields[$((delete_index + 1))]}"

# ---------------------------------------------------------------------------
# §9.2 Only `-z` is byte-exact. Default output C-quotes non-ASCII; core.quotePath=false still quotes
# an embedded double quote. A line-splitting adapter is wrong on both.
# ---------------------------------------------------------------------------
git add -A
git commit -qm second

unicode_name='Ünïcode Spaced.lean'
printf 'u\n' >"$unicode_name"
git add -A
git commit -qm unicode

if git diff --name-status HEAD~1 | grep -qF "$unicode_name"; then
  fail "git diff emitted a raw non-ASCII path without -z; RWI-SPEC §9.2 assumed it C-quotes"
fi
if ! git diff --name-status -z HEAD~1 | tr '\0' '\n' | grep -qF "$unicode_name"; then
  fail "git diff -z did not emit the non-ASCII path byte-exactly"
fi

# ---------------------------------------------------------------------------
# §9.1 Three-dot is the merge-base question; two-dot is not.
# ---------------------------------------------------------------------------
git checkout -q -b feature
printf 'feat\n' >Feat.lean
git add -A
git commit -qm feat
git checkout -q main
printf 'mainonly\n' >MainOnly.lean
git add -A
git commit -qm mainonly
git checkout -q feature

three_dot=$(git diff --name-status -z main...feature | tr '\0' '\n' | grep -c 'lean$' || true)
two_dot=$(git diff --name-status -z main..feature | tr '\0' '\n' | grep -c 'lean$' || true)

if git diff --name-status -z main...feature | tr '\0' '\n' | grep -q '^MainOnly\.lean$'; then
  fail "three-dot diff reported a path the branch never touched"
fi
if ! git diff --name-status -z main..feature | tr '\0' '\n' | grep -q '^MainOnly\.lean$'; then
  fail "two-dot diff did not report MainOnly.lean; RWI-SPEC §9.1 rejected two-dot for exactly that noise"
fi
if [[ "$three_dot" -ge "$two_dot" ]]; then
  fail "three-dot ($three_dot) did not select fewer paths than two-dot ($two_dot)"
fi

# ---------------------------------------------------------------------------
# §9.7 Probe with rev-parse, not diff. Outside a repository rev-parse exits 128 with one clean line;
# git diff exits 129 after dumping its entire option usage.
# ---------------------------------------------------------------------------
outside="$work/not-a-repo"
mkdir -p "$outside"
cd "$outside"

set +e
rev_parse_out=$(git rev-parse --show-toplevel 2>&1)
rev_parse_code=$?
diff_out=$(git diff --name-status HEAD 2>&1)
diff_code=$?
set -e

expect_eq "rev-parse outside a repository exits 128" "128" "$rev_parse_code"
rev_parse_lines=$(printf '%s\n' "$rev_parse_out" | wc -l | tr -d ' ')
expect_eq "rev-parse outside a repository says one thing" "1" "$rev_parse_lines"

if [[ "$diff_code" -eq 128 ]]; then
  fail "git diff now exits 128 outside a repository; RWI-SPEC §9.7 chose rev-parse on the assumption it does not"
fi
diff_lines=$(printf '%s\n' "$diff_out" | wc -l | tr -d ' ')
if [[ "$diff_lines" -lt 10 ]]; then
  fail "git diff outside a repository no longer dumps usage ($diff_lines lines); revisit RWI-SPEC §9.7"
fi

cd "$repo_root"

# §9.7's other half — that a missing binary surfaces as `IO.Process.output` returning exit 255 rather
# than throwing — is deliberately **not** asserted here. It is a fact about Lean's spawn path, and the
# nearest shell equivalent (127 from `env PATH=/nonexistent git`) is a different number produced by a
# different mechanism; asserting it would look like corroboration while testing nothing relevant. The
# measurement lives in `evidence/01-watch-baseline.md` §4, and RWI-IMPL covers it against the real
# adapter.

printf 'lean-fmt watch/git selection characterization passed\n'
