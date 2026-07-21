#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
git rev-parse --is-inside-work-tree >/dev/null

# Native source boundary: lakefiles are executable configuration; every compiled Lean source uses
# private-by-default modules. No Rust workspace, cache, build output, or generated binary is tracked.
sources=()
while IFS= read -r source; do
  case "$source" in
  lakefile.lean | */lakefile.lean) continue ;;
  # Evidence probes under docs/ are run by hand (`lake env lean <file>`) and never globbed into the
  # package, so they are not compiled sources. Some are legacy (non-`module`) on purpose — e.g. the
  # RIR-SPEC probe exercises `parseImports'`, which is `meta`-gated under the module system.
  docs/*) continue ;;
  esac
  sources+=("$source")
done < <(git ls-files '*.lean')

# `module` must be the first *token*, which is not the first line: Lean lets whitespace and comments
# precede the header, and every source here carries a copyright block above it. So the check skips
# what Lean skips — nestable `/- -/` and `--` to end of line — and then demands `module`. Matching on
# the first non-blank line instead would forbid a header Lean accepts, and the gate exists to pin the
# module system, not a comment style.
python3 - "${sources[@]}" <<'PY'
import sys

def first_token(text):
    i, depth = 0, 0
    while i < len(text):
        c = text[i]
        if depth > 0:
            if text.startswith("/-", i):
                depth += 1; i += 2
            elif text.startswith("-/", i):
                depth -= 1; i += 2
            else:
                i += 1
        elif text.startswith("/-", i):
            depth = 1; i += 2
        elif text.startswith("--", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end + 1
        elif c.isspace():
            i += 1
        else:
            end = i
            while end < len(text) and not text[end].isspace():
                end += 1
            return text[i:end]
    return ""

failed = False
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        token = first_token(handle.read())
    if token != "module":
        print(f"{path} does not begin with module (first token: {token!r})", file=sys.stderr)
        failed = True
sys.exit(1 if failed else 0)
PY

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
if [[ $public_entries != "$expected_entries" ]]; then
  printf 'active public entry-point set changed\n%s\n' "$public_entries" >&2
  exit 1
fi

# The compiler plugin depends only on the projection. It cannot acquire the rules, nor the
# application, cache, project, service, CLI, edit, or exact-child orchestration cone.
#
# `LeanFmt.Rules` is named here rather than merely absent: it was in this set, and while it was,
# editing one rule's message text invalidated every integrated module's Lake trace and changed the
# compiled bytes of any module that had a finding (`notes/01-rule-facts.md` §3). The plugin projects;
# findings are computed outside it by whoever holds the facts.
plugin_imports=$(sed -n 's/^import all LeanFmt\.//p' LeanFmt/CompilerPlugin.lean | LC_ALL=C sort)
if [[ $plugin_imports != "ArtifactModel" ]]; then
  printf 'compiler plugin import boundary changed\n%s\n' "$plugin_imports" >&2
  exit 1
fi
# The import graph is only half of it. A Lake library links every module it globs, so a module listed
# below reaches the plugin `.so` — and every integrated module's build graph — whether or not anything
# imports it. `LeanFmt.Rules` was globbed here after its import was already gone.
plugin_globs=$(awk '
  /lean_lib LeanFmtCompilerPlugin where/ { inside=1 }
  inside { print }
  inside && /^  ]/ { exit }
' lakefile.lean)
if grep -Eq 'LeanFmt\.(Application|Cache|Cli|Config|Edit|Project|Rules|Semantic|Service)' \
  <<<"$plugin_globs"; then
  printf 'compiler plugin Lake target includes rule or application modules\n' >&2
  exit 1
fi

# Common callers see only the deepest operation appropriate to their layer.
grep -qx 'import all LeanFmt.Cli' Main.lean
grep -qx 'import all LeanFmt.LanguageServer' LeanFmt/Cli.lean
grep -qx 'import all LeanFmt.Application' LeanFmt/LanguageServer.lean

# The language server takes the toolchain's LSP *data* — DTOs, UTF-16 conversion, JSON-RPC — and none
# of Lean's own server. The rule is scoped to this module on purpose: `LeanFmt/Analysis.lean` imports
# `Lean.Server.InfoUtils` and should, because the info-tree walk is what the semantic occurrence fold
# needs. What must not come back is `Lean.Server.Utils`, whose `applyDocumentChange`/`replaceLspRange`
# convert client positions **without clamping** them — and an unclamped LSP position resolves past the
# end of the buffer, measured (`ruff-17` `evidence/01-position-probe.txt`; `notes/01-protocol.md` §4).
# Reusing those fifteen lines would reintroduce exactly the defect the position layer exists to close.
if rg -n '^import (all )?Lean\.Server' LeanFmt/LanguageServer.lean >/dev/null; then
  printf 'the language server imports Lean.Server; its position layer must clamp\n' >&2
  exit 1
fi
if rg -n 'WorkerFleet|SourceParser|run_project_fleet|FleetPlan|libleanshared|lean-fmt-check-artifacts|--pinned|--jobs' \
  LeanFmt Main.lean lakefile.lean >/dev/null; then
  printf 'legacy execution architecture returned to active production\n' >&2
  exit 1
fi

# The RCI-MODEL proof library must stay out of both link closures. It is a `@[default_target]`, so it
# builds with every ordinary `lake build`, so a proof that stops compiling fails that build — but a
# proof about the cache must never be able to rebuild an integrating project, and Lake links every
# module a library globs. `LeanFmt.Cache.Spec` is globbed alone, in its own target, and nothing imports it.
#
# `LeanFmt.Cache.Decision` is the opposite case and is checked below: it holds the currency decision
# the proof is *about*, `LeanFmt.Cache` and `LeanFmt.Application` call it, so it must be linked. The
# split is the whole point — if the proved function were not in the binary, the proof would again be
# about something other than what runs.
#
# `LeanFmt_Digest` is the positive control: it is genuinely linked, so a zero count there would mean
# this check had stopped looking at anything rather than that the boundary held.
# The decision must be in the binary: the production path calls it.
if [[ -e .lake/build/bin/lean-fmt ]]; then
  if [[ $(nm -a .lake/build/bin/lean-fmt 2>/dev/null |
    grep -c 'LeanFmt_Internal_Cache_Decision') -eq 0 ]]; then
    printf 'the shared currency decision is not linked into the binary; the proof is about dead code\n' >&2
    exit 1
  fi
fi

for image in .lake/build/bin/lean-fmt .lake/build/lib/liblean_x2dfmt_LeanFmtCompilerPlugin.dylib; do
  [[ -e $image ]] || continue
  if [[ $(nm -a "$image" 2>/dev/null | grep -c 'LeanFmt_Internal_Cache_Spec\|LeanFmt_Cache_Spec') -ne 0 ]]; then
    printf 'proof library entered the link closure of %s\n' "$image" >&2
    exit 1
  fi
done
if [[ -e .lake/build/bin/lean-fmt ]]; then
  if [[ $(nm -a .lake/build/bin/lean-fmt 2>/dev/null | grep -c 'LeanFmt_Digest') -eq 0 ]]; then
    printf 'link-closure probe found no LeanFmt_Digest symbols; the probe itself is broken\n' >&2
    exit 1
  fi
fi

grep -q '^package «lean-fmt» where' lakefile.lean
grep -q '^lean_exe «lean-fmt» where' lakefile.lean

printf 'lean-fmt native module and dependency boundary passed\n'
