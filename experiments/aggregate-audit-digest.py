import glob
import hashlib
import json
from collections import Counter

manifest = [l.strip() for l in open('experiments/workloads/mathlib-v4.33.0-rc1-audit.txt') if l.strip()]
reports = {}
for stdout in glob.glob('experiments/results/27-mathlib-*.stdout'):
    try:
        r = json.load(open(stdout))
    except Exception:
        continue
    if not r.get('files'):
        continue
    for f in r['files']:
        reports[f['path']] = f
missing = [p for p in manifest if p not in reports]
print('files reported:', len(reports), 'of', len(manifest), 'missing:', len(missing))
counts = Counter(f['status'] for f in reports.values())
print('status counts:', dict(counts))
# candidates in frozen-manifest order
data = b''
n = 0
for p in manifest:
    f = reports.get(p)
    if f and f.get('formatted'):
        data += f['formatted'].encode()
        n += 1
print('candidates:', n, 'bytes:', len(data))
print('digest:', hashlib.sha256(data).hexdigest())
failures = [(p, reports[p].get('diagnostics', [''])[0][:120]) for p in manifest
            if p in reports and reports[p]['status'] == 'infrastructure-failure']
for p, d in failures:
    print('REFUSAL', p, '|', d)
