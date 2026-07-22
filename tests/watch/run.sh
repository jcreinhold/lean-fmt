#!/usr/bin/env bash
set -euo pipefail

# Characterization suite for the platform behaviors `ruff-16` RWI-SPEC froze
# (see `LeanFmt/Watch.lean`).
#
# RWI-SPEC ships no production surface, so this suite deliberately tests **git and the filesystem**,
# not `lean-fmt`. Every assertion below is a premise the RWI-IMPL selection adapter is built on. If a
# future git changes one of them, the adapter is silently wrong; this suite makes it fail loudly
# instead. RWI-IMPL extends this file with the `lean-fmt` surface itself.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'tests/watch: %s\n' "$1" >&2
  exit 1
}

expect_eq() {
  local what=$1 expected=$2 actual=$3
  if [[ $expected != "$actual" ]]; then
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

if [[ $first_ns == "$second_ns" ]]; then
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
  D) [[ $delete_index -lt 0 ]] && delete_index=$i ;;
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
if [[ $three_dot -ge $two_dot ]]; then
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

if [[ $diff_code -eq 128 ]]; then
  fail "git diff now exits 128 outside a repository; RWI-SPEC §9.7 chose rev-parse on the assumption it does not"
fi
diff_lines=$(printf '%s\n' "$diff_out" | wc -l | tr -d ' ')
if [[ $diff_lines -lt 10 ]]; then
  fail "git diff outside a repository no longer dumps usage ($diff_lines lines); revisit RWI-SPEC §9.7"
fi

# ---------------------------------------------------------------------------
# The CLI surface RWI-IMPL shipped.
#
# These run against the real binary. They are all *rejections* and *error paths*, which are checked
# before any project load, so none of them needs a Lake project or a warm cache — they stay fast. The
# watch loop's own behavior (generations, coalescing, invalidation) is exercised by RWI-FINAL, which
# owns the event-storm work.
# ---------------------------------------------------------------------------
cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt >/dev/null
application=$(lake -q query lean-fmt --text)

expect_rejection() {
  local what=$1 expected_fragment=$2
  shift 2
  set +e
  local output
  output=$("$application" "$@" 2>&1 >/dev/null)
  local code=$?
  set -e
  if [[ $code -ne 2 ]]; then
    fail "$what: expected exit 2, got $code (output: $output)"
  fi
  if [[ $output != *"$expected_fragment"* ]]; then
    printf 'tests/watch: %s\n  expected to mention: %s\n  actual: %s\n' \
      "$what" "$expected_fragment" "$output" >&2
    exit 1
  fi
}

# §10 A writing mode under watch publishes source, which changes the mtimes the poll observes, which
# triggers the next generation. Self-sustaining by construction, so both writers are refused.
expect_rejection "fix --watch" "not available for fix" fix --watch
expect_rejection "format --watch" "not available for format" format --watch

# §7 A stream of documents is not a document, so json/sarif/junit need a destination to replace.
expect_rejection "sarif on stdout under watch" "requires --output-file" \
  check --watch --output-format sarif
expect_rejection "junit on stdout under watch" "requires --output-file" \
  check --watch --output-format junit
expect_rejection "json on stdout under watch" "requires --output-file" \
  format --check --watch --output-format json

# §2 Watch observes disk; a buffer on stdin has no mtime to poll.
expect_rejection "watch with stdin target" "stdin target" \
  check --watch - --stdin-filename x.lean

# A tunable that only means something under --watch is refused elsewhere, rather than silently
# ignored -- the ruff-14/ruff-15 precedent for a flag a mode cannot honor.
expect_rejection "poll interval without watch" "valid only with --watch" check --poll-interval 50

# §9 Naming files and asking git to name them are two answers to one question.
expect_rejection "changed plus explicit files" "do not also name them" \
  check --changed LeanFmt/Doc.lean
expect_rejection "changed-since without a revision" "expects a revision" check --changed-since

# §9.7 An unknown revision names what the caller typed, distinctly from "not a repository".
expect_rejection "unknown revision" "unknown revision: definitely-not-a-ref" \
  check --changed-since definitely-not-a-ref

# §9.7 Outside a repository, the diagnostic is the one clean rev-parse line -- not git diff's usage
# dump, and not a Lean exception.
outside_repo="$work/outside-repo"
mkdir -p "$outside_repo"
set +e
outside_output=$(cd "$outside_repo" && "$application" check --changed --root . 2>&1 >/dev/null)
outside_code=$?
set -e
expect_eq "changed outside a repository exits 2" "2" "$outside_code"
if [[ $outside_output != *"requires a git repository"* ]]; then
  fail "expected a git-repository diagnostic outside a repository, got: $outside_output"
fi
if [[ $outside_output == *"--no-index"* ]]; then
  fail "the non-repository diagnostic leaked git diff's usage text; §9.7 probes with rev-parse"
fi

# §9.6 A selection of zero files is a success with an explicit notice -- never a silent clean report,
# and never the whole project. An empty file list means "everything" to `execute`, so this is the
# assertion that stands between "nothing changed" and "reformat the entire tree".
set +e
staged_output=$("$application" check --staged --root . 2>&1 >/dev/null)
staged_code=$?
set -e
expect_eq "an empty staged selection succeeds" "0" "$staged_code"
if [[ $staged_output != *"no changed Lean sources"* ]]; then
  fail "an empty --staged selection did not say so explicitly: $staged_output"
fi

# §9.6 A non-empty selection discloses that it covers a subset.
printf '\n' >>tests/check/Clean.lean
restore_clean() { cd "$repo_root" && git checkout -- tests/check/Clean.lean 2>/dev/null || true; }
trap 'rm -rf "$work"; restore_clean' EXIT
set +e
changed_output=$("$application" check --changed --root . 2>&1 >/dev/null)
set -e
if [[ $changed_output != *"changed-file selection: worktree vs HEAD"* ]]; then
  fail "a --changed run did not report its comparison: $changed_output"
fi
if [[ $changed_output != *"not the whole project"* ]]; then
  fail "a --changed run did not disclose that it covers a subset: $changed_output"
fi
restore_clean

# ---------------------------------------------------------------------------
# §9.5 Regression: an untracked non-Lean file must not abort a --changed run.
#
# RWI-FINAL found this against a fixture repository and it would hit almost every real user. The
# freeze assumed handing git's paths to `execute` as the request's file list would let the ordinary
# gates drop non-`.lean` and `.lake` paths. It does not: an *explicitly named* file deliberately
# bypasses gates 2-4, and the floor it cannot skip is a hard error. So an ordinary untracked
# `README.md` -- or a `.lake` tree in a repository that does not ignore it -- aborted the entire run
# with `selected file is not a Lean source`. The adapter now applies the floor itself.
# ---------------------------------------------------------------------------
untracked_marker="$repo_root/tests/watch/.regression-untracked.md"
printf 'not a lean source\n' >"$untracked_marker"
cleanup_untracked() { rm -f "$untracked_marker"; }
trap 'rm -rf "$work"; restore_clean; cleanup_untracked' EXIT

set +e
untracked_output=$("$application" check --changed --root . 2>&1 >/dev/null)
untracked_code=$?
set -e
if [[ $untracked_output == *"is not a Lean source"* ]]; then
  fail "an untracked non-Lean file aborted --changed: $untracked_output"
fi
if [[ $untracked_code -ne 0 && $untracked_code -ne 1 ]]; then
  fail "--changed with an untracked non-Lean file exited $untracked_code: $untracked_output"
fi
cleanup_untracked
trap 'rm -rf "$work"; restore_clean' EXIT

# §9.7's other half — that a missing binary surfaces as `IO.Process.output` returning exit 255 rather
# than throwing — is deliberately **not** asserted here. It is a fact about Lean's spawn path, and the
# nearest shell equivalent (127 from `env PATH=/nonexistent git`) is a different number produced by a
# different mechanism; asserting it would look like corroboration while testing nothing relevant. The
# measurement lives in `evidence/01-watch-baseline.md` §4, and RWI-IMPL covers it against the real
# adapter.

printf 'lean-fmt watch/git selection characterization passed\n'
