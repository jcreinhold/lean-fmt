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
other="$project/Fixture/Other.lean"

# §7 adds, deletes, and renames modules, so the whole fixture directory is snapshotted and restored
# rather than three named files.
pristine=$(mktemp -d)
cp -R "$project/Fixture" "$pristine/Fixture"
wide_backup="$pristine/Fixture/Wide.lean"
leaf_backup="$pristine/Fixture/Leaf.lean"

cleanup() {
  rm -rf "$project/Fixture"
  cp -R "$pristine/Fixture" "$project/Fixture"
  rm -rf "$pristine"
  rm -rf "$project/.lean-fmt-cache"
  (cd "$project" && LEAN_NUM_THREADS=1 lake build >/dev/null 2>&1) || true
}
trap cleanup EXIT

fail() {
  printf 'tests/cache: %s\n' "$1" >&2
  exit 1
}

expect_eq() {
  local what=$1 expected=$2 actual=$3
  if [[ $expected != "$actual" ]]; then
    printf 'tests/cache: %s\n  expected: %s\n  actual:   %s\n' "$what" "$expected" "$actual" >&2
    exit 1
  fi
}

[[ -x $fmt ]] || fail "lean-fmt binary not built; run 'lake build' first"

# The fixture needs its own `lean-toolchain` -- `lean-fmt` reads one from the project root -- but a
# committed copy would drift from the repository's. Generate it instead, so there is one source of
# truth. It is gitignored.
cp "$repo_root/lean-toolchain" "$project/lean-toolchain"

# Precondition for the absent-search-path-root regression (`RCI-FINAL`). `tests/cache/dep` is required
# by the fixture and imported by nothing, so Lake never builds its library and the directory below
# never exists -- while still being on the workspace's `LEAN_PATH`. That is mathlib's `Cli` shape, and
# it disabled the cache for entire projects: `IO.FS.realPath` threw on the absent directory and the
# exception escaped into `ResultCache.open?`'s catch-all. Every section below therefore runs with an
# absent root, so the regression fails the whole file. Guard the precondition, or a future `lake build`
# that happens to create the directory would turn all of that into decoration silently.
if [[ -d "$repo_root/tests/cache/dep/.lake/build/lib/lean" ]]; then
  fail "tests/cache/dep has been built; the absent-search-path-root coverage is no longer real"
fi

cd "$project"

work=$(mktemp -d)
trap 'cleanup; rm -rf "$work"' EXIT

# Number of entries served from cache on one `check`.
served() {
  LEAN_FMT_PROFILE_PHASES=1 "$fmt" check 2>&1 | sed -n 's/^cache\.served=//p'
}

# Total targets discovered. Expectations below are written relative to this rather than to a literal,
# so adding a fixture module does not silently turn a real assertion into arithmetic maintenance.
targets() {
  LEAN_FMT_PROFILE_PHASES=1 "$fmt" check 2>&1 | sed -n 's/^cache\.targets=//p'
}

rebuild() {
  LEAN_NUM_THREADS=1 lake build >/dev/null 2>&1 || fail "fixture project failed to build"
}

# For the shapes that deliberately break the build.
rebuild_broken() {
  if LEAN_NUM_THREADS=1 lake build >/dev/null 2>&1; then
    fail "expected the fixture build to fail"
  fi
  return 0
}

# Restore sources *and* build outputs.
#
# Removing a source does not remove its `.olean`: Lake leaves orphaned artifacts behind. Restoring only
# the sources would leave a previous shape's artifact in the build directory, and since the
# whole-workspace fallback digest is computed over that directory, the next shape would measure against
# a polluted baseline. This cost one wrong expectation before it was caught -- §7.1 read "adding a
# module changes nothing" purely because the added module's artifact was already there.
restore_fixture() {
  rm -rf "$project/Fixture" "$project/.lake/build"
  cp -R "$pristine/Fixture" "$project/Fixture"
  rebuild
  served >/dev/null
}

index_count() {
  find "$project/.lean-fmt-cache/results" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

# The stale-hit oracle, and the strongest assertion in this file.
#
# Counting hits shows *how much* was invalidated. It cannot show whether what was served was correct.
# This runs the cached path and the `--no-cache` path against the same build state and requires the
# reports to be byte-identical: if any entry were served under a grammar or source that no longer
# matches, the two would disagree. `SERVED` is set as a side effect so a caller can assert granularity
# and correctness from one pair of runs.
#
# Ordering matters. The cached run must be the *first* `check` after the edit, or an intervening run
# would have already rewritten the entry that was supposed to be caught serving stale.
SERVED=
probe() {
  local label=$1
  set +e
  LEAN_FMT_PROFILE_PHASES=1 "$fmt" check --json >"$work/cached.json" 2>"$work/cached.err"
  local cached_exit=$?
  "$fmt" check --json --no-cache >"$work/uncached.json" 2>"$work/uncached.err"
  local uncached_exit=$?
  set -e
  SERVED=$(sed -n 's/^cache\.served=//p' "$work/cached.err")
  if [[ $cached_exit != "$uncached_exit" ]]; then
    printf 'tests/cache: %s: cached exit %s, --no-cache exit %s\n' \
      "$label" "$cached_exit" "$uncached_exit" >&2
    exit 1
  fi
  if ! cmp -s "$work/cached.json" "$work/uncached.json"; then
    printf 'tests/cache: %s: STALE HIT -- cached report differs from --no-cache\n' "$label" >&2
    diff "$work/uncached.json" "$work/cached.json" >&2 || true
    exit 1
  fi
}

rm -rf "$project/.lake/build"
rebuild
rm -rf "$project/.lean-fmt-cache"
TOTAL=$(targets)
rm -rf "$project/.lean-fmt-cache"
[[ $TOTAL -ge 8 ]] || fail "fixture lost targets: discovered only $TOTAL"

# ---------------------------------------------------------------------------
# §1 Cold populates, warm serves everything.
# ---------------------------------------------------------------------------
expect_eq "cold run serves nothing" 0 "$(served)"
expect_eq "unchanged warm run serves every target" "$TOTAL" "$(served)"
expect_eq "one index file after warming" 1 "$(index_count)"
probe "unchanged tree"
expect_eq "unchanged tree still serves everything under the oracle" "$TOTAL" "$SERVED"

# ---------------------------------------------------------------------------
# §2 A module with no dependents invalidates only itself.
#
# Guards the property the old whole-project source walk destroyed: before this stack, editing one of
# 112 files left 0 entries hitting, because `environment` folded project source bytes into the index
# *filename* and renamed it.
# ---------------------------------------------------------------------------
printf '\n-- entry-granularity probe\n' >>"$leaf"
rebuild
probe "edit of a module with no dependents"
expect_eq "editing a module with no dependents invalidates it and the lakefile only" \
  "$((TOTAL - 2))" "$SERVED"
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
probe "comment-only edit to a dependency"
expect_eq "comment-only edit to a dependency leaves dependents cached" "$((TOTAL - 2))" "$SERVED"
cp "$wide_backup" "$wide"
rebuild
served >/dev/null

# ---------------------------------------------------------------------------
# §4 A semantic edit to a widely-imported module invalidates its dependents.
# ---------------------------------------------------------------------------
sed -i '' 's/def wideValue : Nat := 2/def wideValue : Nat := 42/' "$wide"
grep -q "wideValue : Nat := 42" "$wide" || fail "§4 fixture edit did not apply"
rebuild
probe "semantic edit to a dependency"
expect_eq "semantic edit to a dependency invalidates Wide, User, Other, lakefile" \
  "$((TOTAL - 4))" "$SERVED"
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
# Mutation-checked: with `closureDigest?` returning a constant, this run serves one entry more than
# expected, and the extra entry is `User` -- a stale hit on byte-identical source under a changed
# grammar. `probe` catches it independently of the count, by disagreeing with `--no-cache`.
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
probe "notation-only edit"
expect_eq "a notation edit invalidates Notation, User, lakefile -- and nothing else" \
  "$((TOTAL - 3))" "$SERVED"

# ---------------------------------------------------------------------------
# §6 Revisions do not accumulate index files.
#
# Five rebuild-and-check cycles have run above. A per-revision index would have left one orphan each.
# ---------------------------------------------------------------------------
expect_eq "index file count is still 1 after five revisions" 1 "$(index_count)"

# ---------------------------------------------------------------------------
# §7 Adversarial graph and edit shapes (`ruff-16b` RCI-FINAL).
#
# Every shape below runs through `probe`, so each is checked for *correctness* -- agreement with
# `--no-cache` under the same build state -- and not only for how many entries it invalidated. A stale
# hit under any of these is a stop, not a finding to file.
# ---------------------------------------------------------------------------

# §7.1 A module added. It is new, so it misses; nothing else should.
restore_fixture
printf 'module\n\npublic section\n\ndef addedValue : Nat := 9\n' >"$project/Fixture/Added.lean"
rebuild
probe "module added"
expect_eq "adding a module invalidates the new module and the lakefile only" \
  "$((TOTAL + 1 - 2))" "$SERVED"

# §7.2 A module deleted from the middle of a closure. `User` and `Other` import `Wide`, so the build
# breaks. The point is that neither is served a result computed under the module that vanished.
restore_fixture
rm "$wide"
rebuild_broken
probe "module deleted mid-closure"
expect_eq "deleting an imported module invalidates its dependents" "$((TOTAL - 1 - 2))" "$SERVED"

# §7.3 An import edge added. `Other` gains an import; nothing imports `Other`, so nothing cascades.
restore_fixture
python3 - "$other" <<'EDGE'
import sys
path = sys.argv[1]
source = open(path).read()
assert source.count("import Fixture.Wide") == 1, source
open(path, "w").write(
    source.replace("import Fixture.Wide", "import Fixture.Wide\nimport Fixture.Notation"))
EDGE
rebuild
probe "import edge added"
expect_eq "adding an import edge invalidates the importer and the lakefile only" \
  "$((TOTAL - 2))" "$SERVED"

# §7.4 A module renamed. The old entry is orphaned inside the index; the new name is cold.
restore_fixture
mv "$leaf" "$project/Fixture/Renamed.lean"
rebuild
probe "module renamed"
expect_eq "renaming a module invalidates the new name and the lakefile only" "$((TOTAL - 2))" "$SERVED"
expect_eq "a rename does not create a second index" 1 "$(index_count)"

# §7.5 A change visible only to normalization: LF to CRLF, identical normalized text.
#
# It still misses. Every compiler-produced offset indexes `raw.crlfToLf`, so the *analysis* is
# unchanged -- but `format` and `fix` denormalize back to the file's own line endings when they
# publish, so the raw bytes are part of what an entry promises. Missing is the conservative direction
# and costs one recomputation.
restore_fixture
python3 - "$leaf" <<'CRLF'
import sys
path = sys.argv[1]
data = open(path, "rb").read()
assert b"\r\n" not in data, "fixture is not LF-only"
open(path, "wb").write(data.replace(b"\n", b"\r\n"))
CRLF
rebuild
probe "CRLF-only change"
expect_eq "a CRLF-only change invalidates that file alone" "$((TOTAL - 1))" "$SERVED"

# §7.6 The `choice`-node and `#exit` modules stay served across an unrelated edit.
#
# `Fixture/Choice.lean` carries two notations spelling one token range, so its parse contains a
# `choice` node covering that range twice; `Fixture/Exit.lean` ends its command stream at `#exit` with
# a verbatim tail. Both are inside every count above. This asserts they are actually *served* rather
# than quietly failing into recomputation on every run, which would make their presence decorative.
restore_fixture
printf '\n-- unrelated\n' >>"$leaf"
rebuild
probe "choice and #exit modules across an unrelated edit"
expect_eq "an unrelated edit leaves the choice and #exit modules cached" "$((TOTAL - 2))" "$SERVED"

# ---------------------------------------------------------------------------
# §8 Epoch changes still invalidate everything, and indexes stay bounded.
#
# The index name is a digest of the epoch, not of project sources. `ruff-16b` made project edits stop
# moving it; an epoch change still must.
#
# This section runs last because it deliberately leaves the epoch moved.
# ---------------------------------------------------------------------------
restore_fixture
expect_eq "warm before the epoch moves" "$TOTAL" "$(served)"

# A formatter rebuild is an epoch change: `formatter` is the binary's path, size, and mtime.
touch -m -t 203001010000 "$fmt"
probe "formatter rebuild"
expect_eq "a formatter rebuild invalidates every entry" 0 "$SERVED"

# Repeated epoch changes must not grow the directory without bound. Before RCI-FINAL nothing collected
# indexes at all: three simulated rebuilds left four files, and it kept climbing.
for stamp in 203001010001 203001010002 203001010003 203001010004 203001010005 203001010006; do
  touch -m -t "$stamp" "$fmt"
  served >/dev/null
done
bounded=$(index_count)
if [[ $bounded -gt 4 ]]; then
  fail "index files are not bounded: $bounded after seven epoch changes"
fi
expect_eq "the survivors are the live index plus the retained three" 4 "$bounded"

# A toolchain mismatch is a hard error, not a silent re-key.
cp "$project/lean-toolchain" "$work/lean-toolchain.backup"
printf 'leanprover/lean4:v0.0.0\n' >"$project/lean-toolchain"
set +e
"$fmt" check --json >"$work/toolchain.json" 2>&1
toolchain_exit=$?
set -e
expect_eq "a toolchain mismatch exits 2" 2 "$toolchain_exit"
cp "$work/lean-toolchain.backup" "$project/lean-toolchain"

printf 'tests/cache: ok\n'
