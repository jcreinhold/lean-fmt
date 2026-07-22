#!/usr/bin/env bash
set -euo pipefail

# `ruff-19` RPR-IMPL. What does building a `PositionIndex` actually cost, and what makes it worse?
#
# `ruff-15` handed this stack an unmeasured claim: `report-bench` builds its index *outside* the
# clock (`LeanFmtTest.lean`), so index build -- the one part of rendering that is O(source bytes)
# rather than O(findings) -- had never been measured at all. It also handed over a guess about the
# adversarial shape: "one enormous line, findings clustered at the end of a very large file".
#
# Reading `positionsOf` says the guess is wrong, and this script is the check. The walk is a single
# linear pass over *sorted* offsets, so it stops at the last finding it needs; a finding at the end
# costs a full pass and a finding at the start costs almost none. But `resolvePositions` also runs
# `LosslessSource.normalize` and `String.toUTF8` over the whole file first, unconditionally, for any
# file with at least one finding. If that dominates, then position is irrelevant and *size alone* is
# the adversarial axis -- a different fixture, and a different thing to watch for a regression.
#
# Four shapes, same size, so the only variable is where the findings are:
#
#   early   one finding a few bytes in
#   late    one finding a few bytes from the end
#   many    findings spread evenly through the file
#   oneline the whole body on a single line, one finding at the end -- the column counter's worst
#           case, since every byte increments `column` and none resets it
#
# The finding is FMT001 (forbidden control byte), which fires anywhere in the source, needs no
# frontend, and is report-only, so nothing here writes.
#
# Fixtures are generated into `tests/reporting/` -- excluded from `lean-fmt.toml`, so they never
# enter the lint corpus or the printer's own shape evidence -- and removed on exit. They are
# deliberately not committed: they are a few MB of filler and the script reproduces them exactly.

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

body_bytes=${1:-4000000}
fixtures=tests/reporting/positions-bench
application=$repo_root/.lake/build/bin/lean-fmt

if [[ ! -x $application ]]; then
  printf 'build lean-fmt first: LEAN_NUM_THREADS=1 lake build\n' >&2
  exit 2
fi

cleanup() { rm -rf "$repo_root/$fixtures"; }
trap cleanup EXIT
cleanup
mkdir -p "$fixtures"

python3 - "$fixtures" "$body_bytes" <<'PY'
import pathlib, sys

fixtures = pathlib.Path(sys.argv[1])
body_bytes = int(sys.argv[2])

# A comment body, so the control byte is comment text: FMT001 is report-only there and the file still
# parses. Line length is 80 so the multi-line shapes have a realistic line count.
header = "/-\nCopyright (c) 2026 Jacob Reinhold. All rights reserved.\n-/\n\nmodule\n\n/-\n"
footer = "\n-/\n"
control = "\x01"


def emit(name, body):
    (fixtures / f"{name}.lean").write_text(header + body + footer, encoding="utf-8")


line = "x" * 79 + "\n"
lines = body_bytes // len(line)
filler = line * lines

emit("early", control + filler)
emit("late", filler + control)
emit("many", "".join(line[:-1] + control + "\n" for _ in range(lines)))
emit("oneline", "x" * body_bytes + control)

for path in sorted(fixtures.glob("*.lean")):
    print(f"  {path.name:10s} {path.stat().st_size:>10,d} bytes")
PY

printf '\n%-10s %10s %12s %12s\n' shape bytes positions_ms wall_ms
for shape in early late many oneline; do
  path=$fixtures/$shape.lean
  size=$(wc -c <"$path" | tr -d ' ')
  started=$(python3 -c 'import time;print(int(time.time()*1000))')
  phases=$(LEAN_FMT_PROFILE_PHASES=1 "$application" check --output-format concise \
    --root "$repo_root" "$repo_root/$path" 2>&1 >/dev/null | grep '^phase\.positions_ms=' || true)
  finished=$(python3 -c 'import time;print(int(time.time()*1000))')
  printf '%-10s %10s %12s %12s\n' "$shape" "$size" "${phases#phase.positions_ms=}" \
    "$((finished - started))"
done
