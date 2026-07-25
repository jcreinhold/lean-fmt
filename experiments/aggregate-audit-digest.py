import glob
import hashlib
import json
from collections import Counter

with open("experiments/workloads/mathlib-v4.33.0-rc1-audit.txt") as f:
    manifest = [line.strip() for line in f if line.strip()]
reports = {}
for stdout in glob.glob("experiments/results/27-mathlib-*.stdout"):
    try:
        with open(stdout) as f:
            r = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        continue
    if not r.get("files"):
        continue
    for f in r["files"]:
        reports[f["path"]] = f
missing = [p for p in manifest if p not in reports]
print("files reported:", len(reports), "of", len(manifest), "missing:", len(missing))
counts = Counter(f["status"] for f in reports.values())
print("status counts:", dict(counts))
# candidates in frozen-manifest order
data = b""
n = 0
for p in manifest:
    f = reports.get(p)
    if f and f.get("formatted"):
        data += f["formatted"].encode()
        n += 1
print("candidates:", n, "bytes:", len(data))
print("digest:", hashlib.sha256(data).hexdigest())
failures = [
    (p, reports[p].get("diagnostics", [""])[0][:120])
    for p in manifest
    if p in reports and reports[p]["status"] == "infrastructure-failure"
]
for p, d in failures:
    print("REFUSAL", p, "|", d)
