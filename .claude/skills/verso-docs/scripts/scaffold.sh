#!/usr/bin/env bash
# Create a Verso manual package, pinned to the toolchain this repository already uses.
#
# The Verso revision is derived from lean-toolchain rather than typed, because Verso tags track Lean
# releases one-for-one and a mismatch fails as a wall of elaboration errors that never names the
# cause. The tag is checked against the remote before anything is written.
#
# Usage: scaffold.sh [target-dir]   (default: docs/manual)

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-docs/manual}"
dir="$root/$target"

if [ -e "$dir" ]; then
  echo "error: $target already exists; refusing to overwrite" >&2
  echo "       delete it first, or pass a different target directory" >&2
  exit 1
fi

toolchain="$(tr -d '[:space:]' < "$root/lean-toolchain")"
version="${toolchain#*:}"

if [ -z "$version" ] || [ "$version" = "$toolchain" ]; then
  echo "error: could not read a Lean version from lean-toolchain: '$toolchain'" >&2
  exit 1
fi

echo "Lean toolchain: $toolchain"
echo "Looking for Verso tag $version ..."

if ! git ls-remote --tags --exit-code https://github.com/leanprover/verso.git "refs/tags/$version" >/dev/null 2>&1; then
  echo "error: Verso has no tag '$version'" >&2
  echo "       Verso tags follow Lean releases; the nearest ones are:" >&2
  git ls-remote --tags https://github.com/leanprover/verso.git \
    | awk '{print $2}' | sed 's|refs/tags/||' | grep -v '\^{}' | tail -8 | sed 's/^/         /' >&2
  echo "       Either wait for the matching tag or move lean-toolchain to a version Verso has." >&2
  exit 1
fi

echo "Found it. Writing $target ..."

mkdir -p "$dir/Manual"
printf '%s\n' "$toolchain" > "$dir/lean-toolchain"

cat > "$dir/lakefile.toml" <<EOF
# The Verso documentation package. It is deliberately separate from the lean-fmt package: cache
# identity folds the ordered Lake environment, so a dependency in the root lakefile would invalidate
# every .lean-fmt-cache entry whenever its pin moved. See .claude/skills/verso-docs/SKILL.md.
#
# The verso rev must equal lean-toolchain's version. scripts/check-pins.sh enforces that.
name = "lean-fmt-manual"
defaultTargets = ["Manual", "docs"]

[[require]]
name = "verso"
git = "https://github.com/leanprover/verso"
rev = "$version"

[[lean_lib]]
name = "Manual"

[[lean_exe]]
name = "docs"
root = "Main"
EOF

cat > "$dir/Main.lean" <<'EOF'
import VersoManual
import Manual

open Verso.Genre Manual

def config : RenderConfig where
  emitTeX := false
  emitHtmlSingle := .no
  emitHtmlMulti := .immediately
  htmlDepth := 2
  sourceLink := some "https://github.com/jcreinhold/lean-fmt"
  issueLink := some "https://github.com/jcreinhold/lean-fmt/issues"

def main := manualMain (%doc Manual) (config := config)
EOF

cat > "$dir/Manual.lean" <<'EOF'
import VersoManual

import Manual.Introduction

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "The lean-fmt manual" =>
%%%
tag := "top"
shortTitle := "lean-fmt"
%%%

lean-fmt is a formatter and linter for Lean 4.

{include 1 Manual.Introduction}
EOF

cat > "$dir/Manual/Introduction.lean" <<'EOF'
import VersoManual

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Introduction" =>
%%%
tag := "introduction"
%%%

Replace this with the first chapter. A code example is checked as the document builds, so a snippet
that stops compiling breaks the build rather than quietly becoming wrong:

```lean (name := twiceEval)
def twice (n : Nat) : Nat := n + n

#eval twice 21
```

The expected output is checked too. Naming the block above lets this one quote what it printed, so
the two cannot drift apart:

```leanOutput twiceEval
42
```
EOF

cat > "$dir/.gitignore" <<'EOF'
/.lake/
/_out/
EOF

echo
echo "Wrote:"
find "$dir" -type f | sed "s|$root/|  |" | sort
echo
echo "Next:"
echo "  cd $target && lake exe docs          # first build downloads Verso; minutes"
echo "  python3 $here/serve.py 8000 -d $target/_out/html-multi"
