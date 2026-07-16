#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

# Native source boundary: lakefiles are executable configuration; every compiled Lean source uses
# private-by-default modules. No Rust workspace, cache, build output, or generated binary is tracked.
while IFS= read -r source; do
  case "$source" in
    lakefile.lean|*/lakefile.lean) continue ;;
  esac
  first=$(awk 'NF {print $1; exit}' "$source")
  if [[ "$first" != module ]]; then
    printf '%s does not begin with module\n' "$source" >&2
    exit 1
  fi
done < <(git ls-files '*.lean')

if git ls-files | grep -Eq '(^|/)(Cargo\.toml|Cargo\.lock|[^/]+\.rs|target|\.lake|\.lean-fmt-cache)(/|$)'; then
  printf 'tracked Rust, cache, or build artifact crossed the native source boundary\n' >&2
  exit 1
fi

# The ordinary root exports nothing. Application modules have no explicit public declarations;
# only executable/test entry points are public in the active package.
if grep -Eq '^[[:space:]]*import |^[[:space:]]*(def|structure|inductive|class|abbrev) ' LeanFmt.lean; then
  printf 'LeanFmt root unexpectedly exports or defines application state\n' >&2
  exit 1
fi
if rg -n '^public ' LeanFmt >/dev/null; then
  printf 'application library contains an explicit public declaration\n' >&2
  exit 1
fi
public_entries=$(rg -l '^public (unsafe )?def main' Main.lean LeanFmtArtifactExtract.lean LeanFmtTest.lean | LC_ALL=C sort)
expected_entries=$'LeanFmtArtifactExtract.lean\nLeanFmtTest.lean\nMain.lean'
if [[ "$public_entries" != "$expected_entries" ]]; then
  printf 'active public entry-point set changed\n%s\n' "$public_entries" >&2
  exit 1
fi

# The compiler plugin depends only on the small semantic artifact/rule core. It cannot acquire the
# application, cache, project, service, CLI, edit, or exact-child orchestration cone.
plugin_imports=$(sed -n 's/^import all LeanFmt\.//p' LeanFmt/CompilerPlugin.lean | LC_ALL=C sort)
if [[ "$plugin_imports" != $'ArtifactModel\nRules' ]]; then
  printf 'compiler plugin import boundary changed\n%s\n' "$plugin_imports" >&2
  exit 1
fi
plugin_globs=$(awk '
  /lean_lib LeanFmtCompilerPlugin where/ { inside=1 }
  inside { print }
  inside && /^  ]/ { exit }
' lakefile.lean)
if grep -Eq 'LeanFmt\.(Application|Cache|Cli|Config|Edit|Project|Semantic|Service)' <<<"$plugin_globs"; then
  printf 'compiler plugin Lake target includes application modules\n' >&2
  exit 1
fi

# Common callers see only the deepest operation appropriate to their layer.
grep -qx 'import all LeanFmt.Cli' Main.lean
grep -qx 'import all LeanFmt.Service' LeanFmt/Cli.lean
grep -qx 'import all LeanFmt.Application' LeanFmt/Service.lean
if rg -n 'WorkerFleet|SourceParser|run_project_fleet|FleetPlan|libleanshared|lean-fmt-check-artifacts|--pinned|--jobs' \
    LeanFmt Main.lean lakefile.lean >/dev/null; then
  printf 'legacy execution architecture returned to active production\n' >&2
  exit 1
fi

grep -q '^package «lean-fmt» where' lakefile.lean
grep -q '^lean_exe «lean-fmt» where' lakefile.lean

printf 'lean-fmt native module and dependency boundary passed\n'
