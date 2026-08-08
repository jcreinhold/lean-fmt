#!/usr/bin/env bash
# Verify the docs package still matches the repository it documents.
#
# After a toolchain bump the root lean-toolchain moves and the docs package does not, so the manual
# builds against a Lean that no longer matches the code it describes. Nothing else catches that: the
# docs build succeeds, and the documentation is silently about a different compiler.
#
# Exits 1 on any mismatch. Usage: check-pins.sh [docs-dir ...]   (default: every dir under docs/
# containing a lakefile.toml that requires verso)

set -uo pipefail

root="$(git rev-parse --show-toplevel)"
toolchain="$(tr -d '[:space:]' < "$root/lean-toolchain")"
version="${toolchain#*:}"
status=0

# Bash 3.2 (macOS) has no mapfile, and expanding an empty array under `set -u` is an error there,
# so collect into a newline-separated string instead of an array.
if [ $# -gt 0 ]; then
  dirs="$(printf '%s\n' "$@")"
else
  dirs="$(
    find "$root/docs" -maxdepth 3 -name lakefile.toml 2>/dev/null \
      | while IFS= read -r f; do
          grep -q 'name = "verso"' "$f" 2>/dev/null && dirname "$f"
        done \
      | sed "s|^$root/||"
  )"
fi

if [ -z "$dirs" ]; then
  echo "No Verso docs package found under docs/. Nothing to check."
  echo "To create one: .claude/skills/verso-docs/scripts/scaffold.sh docs/manual"
  exit 0
fi

echo "Repository toolchain: $toolchain"

while IFS= read -r d; do
  [ -n "$d" ] || continue
  dir="$root/${d#"$root/"}"
  echo
  echo "$d"

  if [ ! -f "$dir/lean-toolchain" ]; then
    echo "  FAIL  no lean-toolchain"
    status=1
  else
    docs_toolchain="$(tr -d '[:space:]' < "$dir/lean-toolchain")"
    if [ "$docs_toolchain" = "$toolchain" ]; then
      echo "  ok    lean-toolchain matches"
    else
      echo "  FAIL  lean-toolchain is '$docs_toolchain', repository is '$toolchain'"
      echo "        fix: printf '%s\\n' '$toolchain' > $d/lean-toolchain"
      status=1
    fi
  fi

  rev="$(awk '/name = "verso"/{f=1} f && /rev =/{gsub(/.*rev = "|".*/,""); print; exit}' "$dir/lakefile.toml" 2>/dev/null)"
  if [ -z "$rev" ]; then
    echo "  FAIL  no verso rev found in lakefile.toml"
    status=1
  elif [ "$rev" = "$version" ]; then
    echo "  ok    verso rev matches ($rev)"
  else
    echo "  FAIL  verso rev is '$rev', toolchain wants '$version'"
    echo "        fix: set rev = \"$version\" in $d/lakefile.toml, then run lake update verso there"
    status=1
  fi

  manifest="$dir/lake-manifest.json"
  if [ -f "$manifest" ]; then
    locked="$(python3 -c "
import json,sys
try:
    m=json.load(open('$manifest'))
except Exception:
    sys.exit(0)
for p in m.get('packages',[]):
    if p.get('name')=='verso':
        print(p.get('inputRev') or p.get('rev') or '')
" 2>/dev/null)"
    if [ -n "$locked" ] && [ "$locked" != "$rev" ]; then
      echo "  FAIL  lake-manifest.json pins verso at '$locked', lakefile says '$rev'"
      echo "        fix: run lake update verso in $d"
      status=1
    elif [ -n "$locked" ]; then
      echo "  ok    manifest agrees"
    fi
  fi
done <<EOF
$dirs
EOF

echo
if [ $status -eq 0 ]; then
  echo "All pins aligned."
else
  echo "Pins are out of alignment; the manual would document a different compiler than the code."
fi
exit $status
