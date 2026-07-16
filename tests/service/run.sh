#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
cache_root="$repo_root/.lean-fmt-cache"
trap 'rm -rf "$work" "$cache_root"' EXIT

cd "$repo_root"
rm -rf "$cache_root"
LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

sources=(tests/check/Clean.lean tests/check/Findings.lean)
python3 - "${sources[@]}" >"$work/before" <<'PY'
import hashlib, os, sys
for path in sys.argv[1:]:
    data = open(path, "rb").read()
    stat = os.stat(path)
    print(path, hashlib.sha256(data).hexdigest(), stat.st_mtime_ns, stat.st_mode)
PY

set +e
env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  "$application" check --root . --json --no-cache tests/check/Findings.lean \
  >"$work/batch.json" 2>"$work/batch.stderr"
batch_status=$?
set -e
test "$batch_status" -eq 1

python3 - "$application" "$repo_root" "$work/batch.json" "$work/service-stats.json" <<'PY'
import json
import os
import statistics
import subprocess
import sys
import threading
import time

application, root, batch_path, stats_path = sys.argv[1:]
batch_file = json.load(open(batch_path))["files"][0]
findings_source = open(os.path.join(root, "tests/check/Findings.lean")).read()
clean_source = open(os.path.join(root, "tests/check/Clean.lean")).read()

def start(extra_env=None):
    env = os.environ.copy()
    env["LEAN_NUM_THREADS"] = "1"
    if extra_env:
        env.update(extra_env)
    return subprocess.Popen(
        [application, "serve", "--root", root, "--max-memory", "8"],
        cwd=root, env=env, text=True, bufsize=1,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def send(proc, value):
    proc.stdin.write(json.dumps(value, separators=(",", ":")) + "\n")
    proc.stdin.flush()

def receive(proc):
    line = proc.stdout.readline()
    assert line, f"service exited early: {proc.stderr.read()}"
    return json.loads(line)

def expect_error(response, code):
    assert response["schema"] == "lean-fmt.service.v1"
    assert response["ok"] is False and response["error"]["code"] == code, response

proc = start()
stop_sample = False
peak_rss_kib = 0

def sample_tree():
    global peak_rss_kib
    while not stop_sample:
        output = subprocess.check_output(
            ["/bin/ps", "-axo", "pid=,ppid=,rss="], text=True)
        rows = [tuple(map(int, line.split())) for line in output.splitlines() if line.split()]
        children = {}
        rss = {}
        for pid, ppid, amount in rows:
            children.setdefault(ppid, []).append(pid)
            rss[pid] = amount
        pending = [proc.pid]
        seen = set()
        total = 0
        while pending:
            pid = pending.pop()
            if pid in seen:
                continue
            seen.add(pid)
            total += rss.get(pid, 0)
            pending.extend(children.get(pid, []))
        peak_rss_kib = max(peak_rss_kib, total)
        time.sleep(0.02)

sampler = threading.Thread(target=sample_tree, daemon=True)
sampler.start()

object_id = {"client": [1, "health"]}
send(proc, {"id": object_id, "method": "health"})
health = receive(proc)
assert health["id"] == object_id and health["ok"] and health["result"]["ready"]
assert health["result"]["root"] == root

# Normalized path and exact on-disk bytes match the independent forced-fallback batch result.
send(proc, {"id": "baseline", "method": "analyze",
            "path": "tests/check/../check/Findings.lean", "version": 1,
            "source": findings_source})
baseline = receive(proc)
assert baseline["ok"], baseline
result = baseline["result"]
assert result["path"] == "tests/check/Findings.lean"
for key in ("status", "findings", "diagnostics"):
    assert result[key] == batch_file[key], (key, result[key], batch_file[key])

# Unsaved bytes are analyzed, but never written to the project.
unsaved = clean_source.rstrip("\n") + "  \n"
send(proc, {"id": "unsaved", "method": "analyze",
            "path": "tests/check/Clean.lean", "version": 1, "source": unsaved})
changed = receive(proc)
assert changed["ok"] and changed["result"]["status"] == "findings"
assert [finding["code"] for finding in changed["result"]["findings"]] == ["FMT001"]

# Duplicate/older versions are rejected before even malformed source can reach Lean.
send(proc, {"id": "stale", "method": "analyze", "path": "tests/check/Clean.lean",
            "version": 1, "source": "this is not Lean"})
stale = receive(proc)
expect_error(stale, "stale-version")
assert stale["error"]["latestVersion"] == 1

# Every protocol error is one response and the next request remains live.
proc.stdin.write("{\n")
proc.stdin.flush()
malformed = receive(proc)
expect_error(malformed, "malformed-json")
assert malformed["id"] is None
send(proc, {"id": ["unknown"], "method": "nope"})
unknown = receive(proc)
expect_error(unknown, "unknown-method")
assert unknown["id"] == ["unknown"]
send(proc, {"id": "missing", "method": "analyze", "path": "tests/check/Clean.lean"})
expect_error(receive(proc), "invalid-request")
send(proc, {"id": "escape", "method": "analyze", "path": "../outside.lean",
            "version": 1, "source": "module\n"})
expect_error(receive(proc), "invalid-path")
send(proc, {"id": "large-source", "method": "analyze", "path": "tests/check/Clean.lean",
            "version": 2, "source": "x" * (16 * 1024 * 1024 + 1)})
expect_error(receive(proc), "source-too-large")
proc.stdin.write("x" * (32 * 1024 * 1024 + 1) + "\n")
proc.stdin.flush()
expect_error(receive(proc), "line-too-large")

# Pipelined requests retain strict FIFO order without a concurrent application queue.
for request_id in ["fifo-1", "fifo-2", "fifo-3"]:
    proc.stdin.write(json.dumps({"id": request_id, "method": "health"}) + "\n")
proc.stdin.flush()
assert [receive(proc)["id"] for _ in range(3)] == ["fifo-1", "fifo-2", "fifo-3"]

# Repeated exact snapshots exercise child crash isolation and source release in one service process.
parent_rss = []
payload = "\n-- " + ("editor-snapshot-" * 4096)
for version in range(2, 102):
    source = clean_source.rstrip("\n") + payload + str(version) + "\n"
    send(proc, {"id": version, "method": "analyze", "path": "tests/check/Clean.lean",
                "version": version, "source": source})
    response = receive(proc)
    assert response["ok"] and response["result"]["version"] == version, response
    parent_rss.append(int(subprocess.check_output(
        ["/bin/ps", "-o", "rss=", "-p", str(proc.pid)], text=True).strip()))

# Shutdown wins over a pipelined later request and produces exactly one final response.
proc.stdin.write(json.dumps({"id": "shutdown", "method": "shutdown"}) + "\n")
proc.stdin.write(json.dumps({"id": "after", "method": "health"}) + "\n")
proc.stdin.flush()
shutdown = receive(proc)
assert shutdown["ok"] and shutdown["id"] == "shutdown"
proc.stdin.close()
assert proc.stdout.readline() == ""
assert proc.wait(timeout=20) == 0, proc.stderr.read()
stop_sample = True
sampler.join(timeout=2)

first = statistics.median(parent_rss[:10])
last = statistics.median(parent_rss[-10:])
assert peak_rss_kib < 8 * 1024 * 1024, peak_rss_kib
assert last <= first + 128 * 1024, (first, last)
json.dump({"requests": 100, "peak_rss_kib": peak_rss_kib,
           "first_parent_median_kib": first, "last_parent_median_kib": last},
          open(stats_path, "w"), sort_keys=True)

# Analyzer crashes and resource exhaustion are request errors, not service death.
for environment in ({"LEAN_FMT_TEST_ANALYZER": "/usr/bin/false"},
                    {"LEAN_FMT_TEST_MAX_BYTES": "1"}):
    failed = start(environment)
    send(failed, {"id": "failure", "method": "analyze",
                  "path": "tests/check/Clean.lean", "version": 1,
                  "source": clean_source})
    expect_error(receive(failed), "analysis-failure")
    send(failed, {"id": "still-ready", "method": "health"})
    assert receive(failed)["result"]["ready"] is True
    send(failed, {"id": "done", "method": "shutdown"})
    assert receive(failed)["ok"]
    failed.stdin.close()
    assert failed.wait(timeout=20) == 0

# EOF after an ordinary request is a clean shutdown.
eof = start()
send(eof, {"id": "eof", "method": "health"})
eof.stdin.close()
assert receive(eof)["ok"]
assert eof.wait(timeout=20) == 0
PY

python3 - "${sources[@]}" >"$work/after" <<'PY'
import hashlib, os, sys
for path in sys.argv[1:]:
    data = open(path, "rb").read()
    stat = os.stat(path)
    print(path, hashlib.sha256(data).hexdigest(), stat.st_mtime_ns, stat.st_mode)
PY
cmp "$work/before" "$work/after"
test ! -e "$cache_root"
cat "$work/service-stats.json"
printf '\nlean-fmt editor service integration tests passed\n'
