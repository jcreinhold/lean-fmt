#!/usr/bin/env bash
# `ruff-13` RCD-FINAL acceptance: hierarchical configuration discovery end to end, through the shipped
# binary, on real project trees.
#
# This suite is deliberately separate from `tests/modes/run.sh`. That one owns the *write* path inside
# this repository, where a mistake damages tracked files. This one owns *discovery*, which needs
# arbitrary tree shapes -- nested workspaces, symlink loops, a config outside the root, thousands of
# files -- that cannot be built inside the formatter's own repository without polluting the printer
# corpus and the git index. Every fixture here is a synthetic Lake project under a temporary directory.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt >/dev/null
application=$(lake -q query lean-fmt --text)
toolchain="$repo_root/lean-toolchain"

failures=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
  printf '  FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}
# Assert on a value rather than on an exit status, so a failure prints what it actually saw.
expect() {
  local label=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then ok "$label"; else
    bad "$label"
    printf '       expected: %s\n       actual:   %s\n' "$expected" "$actual" >&2
  fi
}

# A minimal but real Lake project: the formatter loads a workspace for every run, so a fixture without
# a toolchain and a lakefile would exercise the error path instead of discovery.
new_project() {
  local root=$1
  mkdir -p "$root"
  cp "$toolchain" "$root/lean-toolchain"
  printf 'import Lake\nopen Lake DSL\npackage fixture\n' >"$root/lakefile.lean"
}

# The discovered, selected set as a sorted space-separated list of root-relative paths.
selected() {
  local root=$1
  shift
  "$application" check --root "$root" --json --no-cache "$@" 2>/dev/null |
    python3 -c 'import json,sys; print(" ".join(sorted(f["path"] for f in json.load(sys.stdin)["files"])))'
}

show() {
  local root=$1 target=$2
  shift 2
  "$application" config show "$target" --root "$root" --json "$@" 2>/dev/null
}

printf -- '--- nested workspaces: the closest config governs, and does not merge ---\n'
nested="$work/nested"
new_project "$nested"
mkdir -p "$nested/app" "$nested/lib/deep" "$nested/skipped"
printf 'module\n' | tee "$nested/Root.lean" "$nested/app/App.lean" \
  "$nested/lib/Lib.lean" "$nested/lib/deep/Deep.lean" "$nested/skipped/Skipped.lean" >/dev/null
cat >"$nested/.lean-fmt.toml" <<'EOF'
exclude = ["skipped"]
[format]
line-width = 100
EOF
cat >"$nested/lib/.lean-fmt.toml" <<'EOF'
[format]
line-width = 42
EOF
expect "the excluded directory is pruned and every other source is selected" \
  "Root.lean app/App.lean lakefile.lean lib/Lib.lean lib/deep/Deep.lean" \
  "$(selected "$nested")"
expect "the nested config governs its own directory" "42" \
  "$(show "$nested" "$nested/lib/Lib.lean" | python3 -c 'import json,sys; print(next(s["value"] for s in json.load(sys.stdin)["settings"] if s["key"]=="format.line-width"))')"
expect "the nested config governs its subdirectories too" "42" \
  "$(show "$nested" "$nested/lib/deep/Deep.lean" | python3 -c 'import json,sys; print(next(s["value"] for s in json.load(sys.stdin)["settings"] if s["key"]=="format.line-width"))')"
expect "a sibling directory keeps the root config" "100" \
  "$(show "$nested" "$nested/app/App.lean" | python3 -c 'import json,sys; print(next(s["value"] for s in json.load(sys.stdin)["settings"] if s["key"]=="format.line-width"))')"
# The hierarchy must not merge: `lib` never declared an exclude, so it has none -- it does not inherit
# the root's. This is the single decision that separates this design from a layered one.
expect "the nested config did not inherit the root's exclude" "[]" \
  "$(show "$nested" "$nested/lib/Lib.lean" | python3 -c 'import json,sys; print(next(s["value"] for s in json.load(sys.stdin)["settings"] if s["key"]=="exclude"))')"
expect "the root exclude reaches only the subtree it governs" "3" \
  "$(show "$nested" "$nested/skipped/Skipped.lean" | python3 -c 'import json,sys; print(json.load(sys.stdin)["gate"])')"

printf -- '--- extend: composition, anchors, and provenance ---\n'
ext="$work/extend"
new_project "$ext"
mkdir -p "$ext/shared" "$ext/pkg"
printf 'module\n' >"$ext/pkg/Pkg.lean"
cat >"$ext/shared/base.toml" <<'EOF'
[format]
line-width = 90
[lint]
select = ["security"]
extend-select = ["FMT008"]
EOF
cat >"$ext/pkg/.lean-fmt.toml" <<'EOF'
extend = "../shared/base.toml"
[format]
line-width = 42
[lint]
extend-select = ["FMT009"]
EOF
ext_show=$(show "$ext" "$ext/pkg/Pkg.lean")
expect "the extending file wins a scalar" "42" \
  "$(printf '%s' "$ext_show" | python3 -c 'import json,sys; print(next(s["value"] for s in json.load(sys.stdin)["settings"] if s["key"]=="format.line-width"))')"
expect "the parent's base array is inherited" '["security"]' \
  "$(printf '%s' "$ext_show" | python3 -c 'import json,sys; print(next(s["value"] for s in json.load(sys.stdin)["settings"] if s["key"]=="lint.select"))')"
expect "extend-select concatenates parent then child" '["FMT008", "FMT009"]' \
  "$(printf '%s' "$ext_show" | python3 -c 'import json,sys; print(next(s["value"] for s in json.load(sys.stdin)["settings"] if s["key"]=="lint.extend-select"))')"
expect "both contributing files are reported, parent first" "shared/base.toml pkg/.lean-fmt.toml" \
  "$(printf '%s' "$ext_show" | python3 -c '
import json, sys, os
root = sys.argv[1]
print(" ".join(os.path.relpath(f, root) for f in json.load(sys.stdin)["contributingFiles"]))' "$(cd "$ext" && pwd -P)")"
# Provenance is per setting, not per file: the inherited value must name the *parent*, and the
# overriding value the child. A report that named one file for the whole config would pass every
# value assertion above and still be useless for the question users actually ask.
expect "an inherited value names the parent file" "base.toml:4" \
  "$(printf '%s' "$ext_show" | python3 -c 'import json,sys,os; print(os.path.basename(next(s["origin"] for s in json.load(sys.stdin)["settings"] if s["key"]=="lint.select")))')"
expect "an overriding value names the child file" ".lean-fmt.toml:3" \
  "$(printf '%s' "$ext_show" | python3 -c 'import json,sys,os; print(os.path.basename(next(s["origin"] for s in json.load(sys.stdin)["settings"] if s["key"]=="format.line-width")))')"

printf -- '--- extend: cycles and depth terminate, and say so ---\n'
cyc="$work/cycle"
new_project "$cyc"
printf 'module\n' >"$cyc/A.lean"
printf 'extend = "b.toml"\n' >"$cyc/a.toml"
printf 'extend = "a.toml"\n' >"$cyc/b.toml"
printf 'extend = "a.toml"\n' >"$cyc/.lean-fmt.toml"
set +e
cycle_out=$("$application" check --root "$cyc" --no-cache 2>&1)
cycle_rc=$?
set -e
expect "an extend cycle fails rather than hanging" "2" "$cycle_rc"
if printf '%s' "$cycle_out" | grep -qi 'cycle'; then
  ok "the cycle error names the cycle"
else
  bad "the cycle error does not name the cycle"
  printf '       %s\n' "$cycle_out" >&2
fi

printf -- '--- symlinks ---\n'
sym="$work/symlink"
new_project "$sym"
mkdir -p "$sym/real" "$sym/dir"
printf 'module\n' >"$sym/real/Real.lean"
printf 'module\n' >"$sym/dir/Dir.lean"
ln -s ../real/Real.lean "$sym/dir/Link.lean" # a symlinked *file* inside the tree
ln -s .. "$sym/dir/loop"                     # a directory symlink pointing at its own ancestor
printf 'module\n' >"$work/outside.lean"
ln -s "$work/outside.lean" "$sym/Outside.lean" # a symlink whose target is outside the root
sym_selected=$(selected "$sym")
# The walk does not descend into directory symlinks, so a loop terminates and contributes nothing.
# That is the property worth pinning: not that symlinks are "handled", but that the walk is finite.
if printf '%s' "$sym_selected" | grep -q 'loop'; then
  bad "the walk descended into a directory symlink loop"
else
  ok "a directory symlink loop is not descended into (the walk is finite)"
fi
# A symlinked source resolves to its target and is reported once, under the target's own path -- not
# twice under both names. Processing it twice would mean two writes to one file in a single run.
expect "a symlinked source collapses onto its target rather than duplicating it" \
  "dir/Dir.lean lakefile.lean real/Real.lean" "$sym_selected"
expect "the symlink's own path resolves to the target it points at" "real/Real.lean" \
  "$(show "$sym" "$sym/dir/Link.lean" | python3 -c 'import json,sys; print(json.load(sys.stdin)["relativePath"])')"
# A symlink out of the root resolves to its target, and the target is outside the project. Discovering
# it would mean a no-arg `format` writes outside the tree it was pointed at, so the walk drops it and
# `config show` reports gate 1 -- the same floor `.lake` sits behind.
expect "a symlink whose target is outside the root is gate 1" "1" \
  "$(show "$sym" "$sym/Outside.lean" | python3 -c 'import json,sys; print(json.load(sys.stdin)["gate"])')"

printf -- '--- ignore sources ---\n'
ign="$work/ignore"
new_project "$ign"
mkdir -p "$ign/.git/info" "$ign/build" "$ign/keep" "$ign/dot"
printf 'ref: refs/heads/main\n' >"$ign/.git/HEAD"
printf 'module\n' | tee "$ign/build/Built.lean" "$ign/keep/Keep.lean" "$ign/keep/Scratch.tmp.lean" \
  "$ign/dot/Dot.lean" "$ign/Excluded.lean" >/dev/null
printf 'build/\n*.tmp.lean\n' >"$ign/.gitignore"
printf 'Excluded.lean\n' >"$ign/.git/info/exclude"
printf 'dot/\n' >"$ign/.ignore"
expect "every ignore source prunes (.gitignore dir, .gitignore glob, info/exclude, .ignore)" \
  "keep/Keep.lean lakefile.lean" "$(selected "$ign")"
printf '!*.tmp.lean\n' >"$ign/keep/.gitignore"
expect "a nearer .gitignore negation re-includes a file the outer one excluded" \
  "keep/Keep.lean keep/Scratch.tmp.lean lakefile.lean" "$(selected "$ign")"
expect "respect-gitignore = false turns every git source off at once" "6" \
  "$(
    printf 'respect-gitignore = false\n' >"$ign/.lean-fmt.toml"
    selected "$ign" | wc -w | tr -d ' '
  )"
rm "$ign/.lean-fmt.toml"
ign_show=$(show "$ign" "$ign/keep/Keep.lean")
if printf '%s' "$ign_show" | python3 -c '
import json, sys
sources = json.load(sys.stdin)["ignoreSources"]
sys.exit(0 if any(s.endswith("keep/.gitignore") for s in sources)
         and any(s.endswith("info/exclude") for s in sources) else 1)'; then
  ok "config show lists the ignore sources in force"
else
  bad "config show did not list the ignore sources in force"
fi

printf -- '--- explicit paths and force-exclude ---\n'
exp="$work/explicit"
new_project "$exp"
mkdir -p "$exp/vendor"
printf 'module\n' >"$exp/vendor/Vendor.lean"
printf 'module\n' >"$exp/Own.lean"
printf 'exclude = ["vendor"]\n' >"$exp/.lean-fmt.toml"
expect "an excluded directory is absent from a no-arg run" "Own.lean lakefile.lean" "$(selected "$exp")"
expect "an explicitly named excluded path is still processed" "vendor/Vendor.lean" \
  "$(selected "$exp" "$exp/vendor/Vendor.lean")"
printf 'exclude = ["vendor"]\nforce-exclude = true\n' >"$exp/.lean-fmt.toml"
expect "force-exclude applies exclusion to explicitly named paths too" "" \
  "$(selected "$exp" "$exp/vendor/Vendor.lean")"
# `include` is a discovery filter, and `force-exclude` must not silently promote it into a filter on
# explicit paths -- those are different questions, and conflating them would surprise a user who named
# a file outside `include` on purpose.
printf 'include = ["Own.lean"]\nforce-exclude = true\n' >"$exp/.lean-fmt.toml"
expect "force-exclude does not make include reject an explicitly named path" "vendor/Vendor.lean" \
  "$(selected "$exp" "$exp/vendor/Vendor.lean")"

printf -- '--- migration warnings ---\n'
mig="$work/migrate"
new_project "$mig"
printf 'module\n' >"$mig/M.lean"
printf 'select = ["security"]\n' >"$mig/.lean-fmt.toml"
mig_err=$("$application" check --root "$mig" --json --no-cache 2>&1 >/dev/null)
if printf '%s' "$mig_err" | grep -q 'select'; then
  ok "a flat linter key still works and warns on stderr"
else
  bad "a flat linter key produced no deprecation notice"
  printf '       %s\n' "$mig_err" >&2
fi
expect "the notice is emitted once, not once per file" "1" \
  "$(printf '%s' "$mig_err" | grep -c 'deprecat' || true)"
printf 'select = ["security"]\n[lint]\nselect = ["all"]\n' >"$mig/.lean-fmt.toml"
set +e
"$application" check --root "$mig" --no-cache >/dev/null 2>"$work/both.err"
both_rc=$?
set -e
expect "the same key set flat and under [lint] is a hard error" "2" "$both_rc"

printf -- '--- introspection is deterministic and read-only ---\n'
det_a=$(show "$nested" "$nested/lib/deep/Deep.lean")
det_b=$(show "$nested" "$nested/lib/deep/Deep.lean")
expect "two config show invocations agree byte for byte" "$det_a" "$det_b"
before=$(find "$nested" -name '*.lean' -o -name '*.toml' | sort | xargs shasum | shasum)
show "$nested" "$nested/lib/deep/Deep.lean" >/dev/null
after=$(find "$nested" -name '*.lean' -o -name '*.toml' | sort | xargs shasum | shasum)
expect "config show wrote nothing" "$before" "$after"

printf -- '--- large-tree discovery timing ---\n'
big="$work/big"
new_project "$big"
python3 - "$big" <<'PY'
import os, sys
root = sys.argv[1]
# 1,000 sources across 100 directories, 10 nested configs, and a 200-file ignored subtree: enough for
# the walk to dominate any fixed cost, and shaped like a real project rather than one flat directory.
for d in range(100):
    directory = os.path.join(root, f"pkg{d // 20:02d}", f"mod{d:03d}")
    os.makedirs(directory, exist_ok=True)
    for f in range(10):
        open(os.path.join(directory, f"F{f}.lean"), "w").write("module\n")
    if d % 10 == 0:
        open(os.path.join(directory, ".lean-fmt.toml"), "w").write("[format]\nline-width = 80\n")
os.makedirs(os.path.join(root, "ignored"), exist_ok=True)
for f in range(200):
    open(os.path.join(root, "ignored", f"I{f}.lean"), "w").write("module\n")
open(os.path.join(root, ".gitignore"), "w").write("ignored/\n")
PY
# Timing goes through `config show`, not `check`, on purpose: `config show` runs discovery and nothing
# else. A `check` over the same tree takes minutes, but essentially none of that is the walk -- it is
# the cold per-file pipeline, a workload `CLAUDE.md` already names and this stack does not own.
# Measuring through `check` would report that cost as if discovery had caused it.
deep=$(LEAN_FMT_PROFILE_PHASES=1 "$application" config show "$big/pkg04/mod099/F9.lean" \
  --root "$big" --json 2>"$work/big.err")
expect "the walk reaches the deepest directory of a 1,200-file tree" "0" \
  "$(printf '%s' "$deep" | python3 -c 'import json,sys; print(json.load(sys.stdin)["gate"])')"
# `mod090` carries a config and `mod099` does not. They are siblings, so `mod099` falls back to the
# root -- it must not pick up its neighbor's width. At this scale a resolution bug that walked the
# directory *list* instead of the path's own ancestry would show up here and nowhere else.
expect "a directory with its own config uses it" "80" \
  "$("$application" config show "$big/pkg04/mod090/F0.lean" --root "$big" --json 2>/dev/null |
    python3 -c 'import json,sys; print(next(s["value"] for s in json.load(sys.stdin)["settings"] if s["key"]=="format.line-width"))')"
expect "a sibling directory without one falls back to the root, not to its neighbor" "100" \
  "$(printf '%s' "$deep" | python3 -c 'import json,sys; print(next(s["value"] for s in json.load(sys.stdin)["settings"] if s["key"]=="format.line-width"))')"
expect "the ignored 200-file subtree is pruned at scale" "2" \
  "$("$application" config show "$big/ignored/I0.lean" --root "$big" --json 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["gate"])')"
discovery_ms=$(sed -nE 's/^phase\.discovery_ms=([0-9]+)$/\1/p' "$work/big.err")
printf '  info discovery over 1,200 files with 10 nested configs: %s ms\n' "$discovery_ms"
# A bound, not a benchmark. The claim RCD-FINAL owes is that one walk is not on the critical path; a
# walk per file would be. The threshold is loose so this fails on a design regression rather than on a
# slow machine -- per-file walking would put this in the tens of seconds, not near the bound.
if [[ $discovery_ms -lt 2000 ]]; then
  ok "discovery stays well under the 2s design bound"
else
  bad "discovery took ${discovery_ms}ms over 1,200 files -- suspect a walk per file"
fi
# The symlink loop and the large tree together: a walk that followed directory symlinks would multiply
# this tree by the loop depth, which is how the defect this stack fixed would have come back.
ln -s .. "$big/pkg04/loop"
loop_ms=$(LEAN_FMT_PROFILE_PHASES=1 "$application" config show "$big/pkg04/mod099/F9.lean" \
  --root "$big" --json 2>&1 >/dev/null | sed -nE 's/^phase\.discovery_ms=([0-9]+)$/\1/p')
printf '  info discovery over the same tree with a symlink loop in it: %s ms\n' "$loop_ms"
if [[ $loop_ms -lt 2000 ]]; then
  ok "a symlink loop inside a large tree does not multiply the walk"
else
  bad "a symlink loop multiplied the walk (${loop_ms}ms) -- directory symlinks are being followed"
fi

printf -- '--- result ---\n'
printf 'failures=%s\n' "$failures"
[[ $failures -eq 0 ]] || exit 1
printf 'lean-fmt configuration discovery acceptance tests passed\n'
