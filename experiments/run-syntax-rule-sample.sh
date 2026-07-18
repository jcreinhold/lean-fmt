#!/usr/bin/env bash
# RYR-FINAL differential + false-positive review. Runs the six syntax-tier rules FMT008-FMT013 over
# the frozen 62-module mathlib sample through lean-fmt's exact frontend (the fixtures are unbuilt
# mathlib modules, so there is no formatter facet in their `.olean`s; disabling the artifact forces
# the exact frontend, which re-elaborates the single module against mathlib's prebuilt deps in ~1-3s).
#
# For every finding it records the module, code, byte range, message, and the exact normalized source
# slice the range names -- so each finding can be reviewed by eye as a true or false positive. mathlib
# is heavily self-linted for the FMT008/009/010/011/012 equivalents, so those are expected near-zero;
# FMT013 (redundant nested parens) has no mathlib linter and is the rule whose true tree-shape rate
# this run measures. Writes an evidence dir under experiments/results; captures stdout for the summary.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
result_root="$repo_root/experiments/results/syntax-rule-sample-$stamp"
mkdir -p "$result_root/reports"
cp "$sources" "$result_root/sources.txt"

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt >/dev/null
application="$repo_root/.lake/build/bin/lean-fmt"

findings_tsv="$result_root/findings.tsv"
printf 'module\tcode\tstart\tstop\tmessage\tslice\n' >"$findings_tsv"
status_tsv="$result_root/status.tsv"
printf 'index\tmodule\tseconds\tfindings\tbroken\tinfra\n' >"$status_tsv"

index=0
while IFS= read -r module; do
  [[ -z "$module" ]] && continue
  index=$((index + 1))
  report="$result_root/reports/$index.json"
  t0=$(python3 -c 'import time; print(time.monotonic())')
  set +e
  env LEAN_FMT_DISABLE_ARTIFACT=1 "$application" check --root "$mathlib_root" --json --no-cache \
    --select FMT008 --select FMT009 --select FMT010 --select FMT011 --select FMT012 --select FMT013 \
    "$module" >"$report" 2>"$report.err"
  set -e
  t1=$(python3 -c 'import time; print(time.monotonic())')
  MATHLIB_ROOT="$mathlib_root" MODULE="$module" SECONDS_ELAPSED=$(python3 -c "print(round($t1-$t0,2))") \
    python3 - "$report" "$findings_tsv" "$status_tsv" "$index" <<'PY'
import json, os, sys
report_path, findings_tsv, status_tsv, index = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
module = os.environ["MODULE"]
seconds = os.environ["SECONDS_ELAPSED"]
mathlib_root = os.environ["MATHLIB_ROOT"]
try:
    data = json.load(open(report_path))
except Exception as exc:
    with open(status_tsv, "a") as fh:
        fh.write(f"{index}\t{module}\t{seconds}\t?\t?\tLOAD_ERROR:{exc}\n")
    raise SystemExit(f"report parse failed for {module}: {exc}")
# The exact frontend indexes the normalized source (`raw.crlfToLf`) by BYTE offset -- Lean's
# String.Pos is a byte position, not a codepoint index. Slice the normalized *bytes* and decode after,
# so a range that spans a multibyte char (this sample has `↦`, `·`, `ϕ`) lands where the finding says.
raw = open(os.path.join(mathlib_root, module), "rb").read()
norm = raw.replace(b"\r\n", b"\n")
fh = open(findings_tsv, "a")
for file in data["files"]:
    for finding in file["findings"]:
        rng = finding["range"]
        sl = norm[rng["start"]:rng["stop"]].decode("utf-8", "replace").replace("\t", "\\t").replace("\n", "\\n")
        fh.write(f"{module}\t{finding['code']}\t{rng['start']}\t{rng['stop']}\t"
                 f"{finding['message']}\t{sl}\n")
fh.close()
with open(status_tsv, "a") as fh:
    fh.write(f"{index}\t{module}\t{seconds}\t{data['findings']}\t{data['broken']}\t"
             f"{len(data['infrastructureFailures'])}\n")
PY
done <"$result_root/sources.txt"

python3 - "$findings_tsv" "$status_tsv" >"$result_root/summary.txt" <<'PY'
import csv, sys
from collections import Counter
findings_tsv, status_tsv = sys.argv[1], sys.argv[2]
findings = list(csv.DictReader(open(findings_tsv), delimiter="\t"))
status = list(csv.DictReader(open(status_tsv), delimiter="\t"))
by_code = Counter(f["code"] for f in findings)
broken = [s for s in status if s["broken"] not in ("0", "?")]
infra = [s for s in status if s["infra"] not in ("0", "?")]
print(f"modules={len(status)}")
print(f"total_findings={len(findings)}")
for code in ("FMT008", "FMT009", "FMT010", "FMT011", "FMT012", "FMT013"):
    print(f"  {code}={by_code.get(code, 0)}")
print(f"broken_modules={len(broken)}: {[s['module'] for s in broken]}")
print(f"infra_failures={len(infra)}: {[s['module'] for s in infra]}")
secs = [float(s['seconds']) for s in status]
print(f"seconds_total={sum(secs):.1f} seconds_max={max(secs):.1f}")
PY
cat "$result_root/summary.txt"

printf '%s\n' "$result_root"
