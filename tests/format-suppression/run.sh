#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)
fixture=tests/format-suppression/Suppressed.lean
lake setup-file "$fixture" >"$work/setup.json"
eof_fixture=tests/format-suppression/EofComment.lean
lake setup-file "$eof_fixture" >"$work/eof-setup.json"

for width in 20 100; do
  "$application" __analyze-exact "$work/setup.json" "$fixture" Suppressed.lean \
    8589934592 "4:$width" >"$work/$width.json"
done

perl -pe 's/\n/\r\n/g' "$fixture" >"$work/crlf.lean"
"$application" __analyze-exact "$work/setup.json" "$work/crlf.lean" Suppressed.lean \
  8589934592 4:100 >"$work/crlf.json"

"$application" check --output-format json --root . \
  tests/format-suppression/Unmatched.lean tests/format-suppression/Header.lean \
  >"$work/malformed.json" || true

"$application" __analyze-exact "$work/eof-setup.json" "$eof_fixture" EofComment.lean \
  8589934592 4:100 >"$work/eof.json"

python3 - "$work" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
texts = {}
for width in (20, 100):
    report = json.loads((root / f"{width}.json").read_text())
    assert report.get("validationFailure") is None and report.get("canonical") is not None, report
    canonical = report["canonical"]
    assert canonical["validation"]["idempotencePasses"] == 1, canonical
    text = canonical["text"]
    texts[width] = text
    assert text.count("-- lean-fmt: format-ignore-next") == 1, text
    assert "def preserved(alpha:Nat):Nat:=alpha+1" in text, text
    assert "def resumed" in text and "beta + 1" in text, text

crlf = json.loads((root / "crlf.json").read_text())
assert crlf.get("validationFailure") is None and crlf.get("canonical") is not None, crlf
assert crlf["canonical"]["text"] == texts[100], "LF/CRLF normalized suppression diverged"
assert texts[20] != texts[100], "formatting did not resume with width-sensitive layout"

malformed = json.loads((root / "malformed.json").read_text())
findings = [finding for file in malformed["files"] for finding in file["findings"]]
assert [finding["code"] for finding in findings] == ["FMT901", "FMT901"], findings
messages = "\n".join(finding["message"] for finding in findings)
assert "cannot target the module/import header" in messages, messages
assert "has no following ordinary unit" in messages, messages
eof = json.loads((root / "eof.json").read_text())
assert eof.get("validationFailure") is None and eof.get("canonical") is not None, eof
assert eof["canonical"]["text"].endswith("-- 𝔽𝔽 tail\n"), eof["canonical"]["text"]
print("  ok   format-ignore-next copies one complete unit and canonical formatting resumes")
print("  ok   suppression is idempotent at widths 20/100 and identical after CRLF normalization")
print("  ok   header-spanning and unmatched formatter directives are non-silent FMT901 findings")
print("  ok   a final file-owned Unicode comment survives exactly once")
PY

printf 'tests/format-suppression: ok\n'
