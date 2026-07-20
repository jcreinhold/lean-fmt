#!/usr/bin/env bash
set -euo pipefail

# Entry-granularity cache invalidation (`ruff-16b` RCI-IMPL).
#
# The claim under test is the one `RCI-SPEC` froze and `LeanFmt/Cache/Spec.lean` proved over a pure
# decision function: an entry is served only when its source **and its grammar** are current, and an
# edit invalidates the entries that depend on it and no others.
#
# This runs against `tests/cache/project`, a self-contained Lean package, and not against the lean-fmt
# repository itself. That is deliberate. Editing any `LeanFmt/*.lean` rebuilds the `lean-fmt` binary,
# which moves `formatter`, which feeds `baseDigest`, which *names the index file* -- so a self-hosted
# measurement invalidates everything for a reason that has nothing to do with the property being
# measured. A separate package holds the formatter fixed and lets one variable move at a time.
#
# The fixture's import graph:
#
#     Notation  (declares `notation:65 a " <+> " b`)
#        ^
#        |
#      User  ---> Wide <--- Other          Leaf   (nothing imports it)
#
# `lakefile.lean` is a sixth target. It is not a workspace module, so it is keyed by the conservative
# whole-workspace artifact digest and misses on *any* rebuild. Every expected count below includes it.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
project="$repo_root/tests/cache/project"
fmt="$repo_root/.lake/build/bin/lean-fmt"

notation="$project/Fixture/Notation.lean"
wide="$project/Fixture/Wide.lean"
leaf="$project/Fixture/Leaf.lean"

notation_backup=$(mktemp)
wide_backup=$(mktemp)
leaf_backup=$(mktemp)
cp "$notation" "$notation_backup"
cp "$wide" "$wide_backup"
cp "$leaf" "$leaf_backup"

cleanup() {
  cp "$notation_backup" "$notation"
  cp "$wide_backup" "$wide"
  cp "$leaf_backup" "$leaf"
  rm -f "$notation_backup" "$wide_backup" "$leaf_backup"
  rm -rf "$project/.lean-fmt-cache"
  (cd "$project" && LEAN_NUM_THREADS=1 lake build >/dev/null 2>&1) || true
}
trap cleanup EXIT

fail() { printf 'tests/cache: %s\n' "$1" >&2; exit 1; }

expect_eq() {
  local what=$1 expected=$2 actual=$3
  if [[ "$expected" != "$actual" ]]; then
    printf 'tests/cache: %s\n  expected: %s\n  actual:   %s\n' "$what" "$expected" "$actual" >&2
    exit 1
  fi
}

[[ -x "$fmt" ]] || fail "lean-fmt binary not built; run 'lake build' first"

# The fixture needs its own `lean-toolchain` -- `lean-fmt` reads one from the project root -- but a
# committed copy would drift from the repository's. Generate it instead, so there is one source of
# truth. It is gitignored.
cp "$repo_root/lean-toolchain" "$project/lean-toolchain"

cd "$project"

# Number of entries served from cache on one `check`.
served() {
  LEAN_FMT_PROFILE_PHASES=1 "$fmt" check 2>&1 | sed -n 's/^cache\.served=//p'
}

rebuild() {
  LEAN_NUM_THREADS=1 lake build >/dev/null 2>&1 || fail "fixture project failed to build"
}

index_count() {
  find "$project/.lean-fmt-cache/results" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

rebuild
rm -rf "$project/.lean-fmt-cache"

# ---------------------------------------------------------------------------
# §1 Cold populates, warm serves everything.
# ---------------------------------------------------------------------------
expect_eq "cold run serves nothing" 0 "$(served)"
expect_eq "unchanged warm run serves every target" 6 "$(served)"
expect_eq "one index file after warming" 1 "$(index_count)"

# ---------------------------------------------------------------------------
# §2 A module with no dependents invalidates only itself.
#
# Guards the property the old whole-project source walk destroyed: before this stack, editing one of
# 112 files left 0 entries hitting, because `environment` folded project source bytes into the index
# *filename* and renamed it.
# ---------------------------------------------------------------------------
printf '\n-- entry-granularity probe\n' >>"$leaf"
rebuild
expect_eq "editing a module with no dependents invalidates it and the lakefile only" 4 "$(served)"
cp "$leaf_backup" "$leaf"
rebuild
served >/dev/null

# ---------------------------------------------------------------------------
# §3 A comment-only edit to a widely-imported module does not invalidate its dependents.
#
# Lake's outputs are content-addressed, so a comment does not move `importAllArts` and the dependents'
# grammar is provably unchanged. This is a precision property an mtime-based key could not have.
# ---------------------------------------------------------------------------
printf '\n-- comment only\n' >>"$wide"
rebuild
expect_eq "comment-only edit to a dependency leaves dependents cached" 4 "$(served)"
cp "$wide_backup" "$wide"
rebuild
served >/dev/null

# ---------------------------------------------------------------------------
# §4 A semantic edit to a widely-imported module invalidates its dependents.
# ---------------------------------------------------------------------------
sed -i '' 's/def wideValue : Nat := 2/def wideValue : Nat := 42/' "$wide"
grep -q "wideValue : Nat := 42" "$wide" || fail "§4 fixture edit did not apply"
rebuild
expect_eq "semantic edit to a dependency invalidates Wide, User, Other, lakefile" 2 "$(served)"
cp "$wide_backup" "$wide"
rebuild
served >/dev/null

# ---------------------------------------------------------------------------
# §5 The open-grammar hazard: editing only a `notation` re-analyzes its *users*, whose bytes never
# changed.
#
# This is the case a source-digest-only key cannot see, and the reason `CacheIdentity` carries
# `closure` at all. `Other` and `Leaf` must keep hitting -- catching the hazard must not mean
# invalidating the world.
#
# Mutation-checked: with `closureDigest?` returning a constant, this run serves 4 instead of 3, and
# the extra entry is `User` -- a stale hit on byte-identical source under a changed grammar.
# ---------------------------------------------------------------------------
user_before=$(md5 -q "$project/Fixture/User.lean")
# Assert the *precondition*, not just the postcondition: a fixture already left in the edited state
# would make the sed a no-op that a postcondition-only guard still accepts.
grep -q 'b => a + b' "$notation" || fail "§5 fixture is not in its baseline state"
sed -i '' 's|notation:65 a " <+> " b => a + b|notation:65 a " <+> " b => a * b|' "$notation"
grep -q 'b => a \* b' "$notation" || fail "§5 notation edit did not apply"
rebuild
user_after=$(md5 -q "$project/Fixture/User.lean")
expect_eq "User's bytes are untouched by the notation edit" "$user_before" "$user_after"
expect_eq "a notation edit invalidates Notation, User, lakefile -- and nothing else" 3 "$(served)"

# ---------------------------------------------------------------------------
# §6 Revisions do not accumulate index files.
#
# Five rebuild-and-check cycles have run above. A per-revision index would have left one orphan each.
# ---------------------------------------------------------------------------
expect_eq "index file count is still 1 after five revisions" 1 "$(index_count)"

printf 'tests/cache: ok\n'
