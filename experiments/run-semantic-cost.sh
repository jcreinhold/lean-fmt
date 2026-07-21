#!/usr/bin/env bash
set -euo pipefail

# RSF-FINAL cost envelope (ruff-05b). Measures the time and peak aggregate RSS of the semantic
# notation-spacing capture against the syntax-only baseline, on the frozen mathlib sample, via the
# real `__analyze-exact` production path. Two profiled passes over one identical, pre-generated set of
# setups — `captureSemantic=0` (baseline) and `captureSemantic=1` (semantic) — are compared; the
# difference is the fact's marginal cost. `profile-run.sh` enforces the 8 GiB / 256 MiB-swap ceiling.

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
maxb=8589934592

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)
application=$(cd "$(dirname "$application")" && pwd)/$(basename "$application")

driver="$repo_root/experiments/semantic-capture-cost-driver.sh"
setup_dir="$scratch/setups"
mkdir -p "$setup_dir"

cd "$mathlib_root"
mathlib_lean_path=$(lake env printenv LEAN_PATH)

# Pre-generate setups once, outside the profiled region, so both passes reuse identical inputs.
index=0
while IFS= read -r source; do
  [[ -n $source ]] || continue
  index=$((index + 1))
  LEAN_NUM_THREADS=1 lake setup-file "$source" >"$setup_dir/$index.setup.json" 2>/dev/null
done <"$sources"
printf 'pre-generated %d setups\n' "$index" >&2

cd "$repo_root"
profile="$repo_root/experiments/profile-run.sh"

run_pass() {
  local name=$1 cap=$2
  LEAN_FMT_PROFILE_BINARY="$application" "$profile" \
    --name "$name" --project-root "$mathlib_root" \
    --build-state prebuilt --cache-state cold --sources "$sources" \
    -- bash "$driver" "$cap" "$sources" "$setup_dir" "$mathlib_root" \
    "$application" "$mathlib_lean_path" "$maxb"
}

baseline_meta=$(run_pass semantic-cost-baseline 0)
semantic_meta=$(run_pass semantic-cost-semantic 1)

python3 - "$baseline_meta" "$semantic_meta" <<'PY'
import sys
def meta(path):
    d = {}
    for line in open(path):
        line = line.rstrip("\n")
        if "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d
b, s = meta(sys.argv[1]), meta(sys.argv[2])
def phase(path, key):
    base = path.rsplit(".meta", 1)[0]
    for line in open(base + ".phases"):
        if line.startswith(key + "="):
            return int(line.split("=", 1)[1])
    return None
print("=== RSF-FINAL semantic capture cost envelope ===")
print(f"machine={b['machine']}")
print(f"toolchain={b['lean_toolchain'].strip()}  lean_fmt_commit={b['lean_fmt_revision']}")
print(f"mathlib_commit={b['project_revision']}  workload={b['source_manifest']}  files={b['source_count']}")
print(f"rss_limit_kib={b['rss_limit_kib']}  swap_limit_kib={b['swap_limit_kib']}")
print()
for name, m in (("baseline (captureSemantic=0)", b), ("semantic (captureSemantic=1)", s)):
    print(f"[{name}]")
    print(f"  exit_status={m['exit_status']}  hard_stop={m['hard_stop']}")
    print(f"  wall_ms={m['wall_ms']}  peak_rss_kib={m['peak_rss_kib']}"
          f"  swap_delta_kib={m['swap_delta_kib']}  peak_pressure_level={m['peak_pressure_level']}")
print()
cn = phase(sys.argv[2], "phase.captured_notations_ms")
cn_b = phase(sys.argv[1], "phase.captured_notations_ms")
print(f"captured_notations: baseline={cn_b}  semantic={cn}")
dw = int(s['wall_ms']) - int(b['wall_ms'])
dr = int(s['peak_rss_kib']) - int(b['peak_rss_kib'])
print(f"delta_wall_ms={dw}  delta_peak_rss_kib={dr}")
assert b['hard_stop'] == 'none' and s['hard_stop'] == 'none', "resource envelope exceeded"
assert cn and cn > 0, "semantic pass captured nothing — the measurement is vacuous"
assert cn_b == 0, "baseline captured notations — captureSemantic=0 is leaking"
print("OK: within envelope; semantic pass captured facts, baseline did not")
PY
