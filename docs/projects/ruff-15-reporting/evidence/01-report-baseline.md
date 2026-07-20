# Reporting baseline — before RRF-IMPL

Owner: `ruff-15-reporting` prompt `01-schema` (claim `RRF-SPEC`). Freeze: `notes/01-report-formats.md`.

Everything below was measured on this machine, not inferred.

- Commit: `00f1825`
- Toolchain: `leanprover/lean4:v4.33.0-rc1`
- Machine: Darwin arm64
- Build: `LEAN_NUM_THREADS=1 lake build` → `Build completed successfully (44 jobs).`
- Fixture: `tests/check/Findings.lean` (duplicate `import LeanFmt.Basic`, one FMT005 finding)

No performance measurement is recorded here: this prompt ships no production code, so there is no
workload to profile. `RRF-FINAL` owns the large-synthetic-report benchmark the roadmap requires.

---

## 1. The current surface

```sh
run(){ printf '$ lean-fmt %s\n' "$*"; lake exe lean-fmt "$@" 2>&1; printf 'exit=%s\n\n' "$?"; }
run check tests/check/Findings.lean
run check tests/check/Findings.lean --json
run check tests/check/Findings.lean --output-format json
run check tests/check/Findings.lean --output-file /tmp/x.json
```

```
$ lean-fmt check tests/check/Findings.lean
tests/check/Findings.lean:29-49: FMT005 duplicate import of LeanFmt.Basic [safe]
mode=check files=1 findings=1 changed=1 written=0 broken=0 rejected=0 withheld_unsafe=0 suppressed=0 infrastructure_failures=0
exit=1

$ lean-fmt check tests/check/Findings.lean --json
{"broken":0,"changed":1,"files":[…],"findings":1,"infrastructureFailures":[],"mode":"check","rejected":0,"suppressed":0,"withheldRedundant":0,"withheldUnsafe":0,"written":0}
exit=1

$ lean-fmt check tests/check/Findings.lean --output-format json
unknown option: --output-format
exit=2

$ lean-fmt check tests/check/Findings.lean --output-file /tmp/x.json
unknown option: --output-file
exit=2
```

**Established:** there are exactly two report renderings (`text`, `json`); neither carries a line, a
column, or a character offset; there is no output-file surface. Both new flags are rejected by
`parseFileArgs`'s catch-all, the same way `ruff-14` found `--range` rejected before it.

---

## 2. The JSON compatibility golden

`evidence/01-json-golden-check.json` is the **verbatim stdout** of

```sh
lake exe lean-fmt check tests/check/Findings.lean --json
```

recorded at commit `00f1825`, *before* any RRF-IMPL change.

```
sha256  a6bc31ad6272e83866903d276390c6b69281081f90623a31ed151b0db4bbe764
exit    1
```

`notes/01-report-formats.md` §8.1 promises `--output-format json` and `--json` reproduce these bytes
exactly. This file is the artifact that makes that promise checkable rather than asserted; RRF-IMPL and
RRF-FINAL both diff against it.

---

## 3. Per-mode report content

Same fixture, `--json`, one mode per row. `tests/check/Findings.lean` was restored with
`git checkout --` after the `fix` run, which publishes in place.

| Mode | `files[].findings` | `files[].diff` | `files[].status` | `written` |
| --- | --- | --- | --- | --- |
| `check` | 1 × FMT005 | `null` | `findings` | 0 |
| `fix` | 1 × FMT005 | `null` | `fixed` | 1 |
| `format --check` | 1 × FMT005 | `null` | `clean` | 0 |
| `diff` | `[]` | `null` (file is canonically clean) | `clean` | 0 |

**Established:** `diff` carries no findings — its product is the patch in `files[].diff`. This is why
`notes` §2.3 rejects the finding-shaped formats for `diff` instead of rendering an empty report that
would read as "clean".

Note also that `format --check` reports the FMT005 finding while `diff` does not: `diff` is
layout-only. Both are correct at their own granularity and RRF-IMPL must not "reconcile" them.

---

## 4. Path shape

```sh
$ lake exe lean-fmt check "$PWD/tests/check/Findings.lean" --json | jq -r '.files[].path'
tests/check/Findings.lean
```

**Established:** an absolute argument is reported root-relative. A URI-based format (`sarif`) therefore
has a well-defined `%SRCROOT%` and needs no path heuristics.

---

## 5. Position arithmetic for the fixture

The FMT005 finding's `range` is `{start: 29, stop: 49}`; its fix edit is `{start: 29, stop: 50}`.
Converted with the frozen encoding (1-based line, 1-based **codepoint** column, `notes` §3.1):

```py
b = open('tests/check/Findings.lean','rb').read().replace(b'\r\n', b'\n')
def lc(off):
    pre = b[:off]
    ls  = pre.rfind(b'\n') + 1
    return pre.count(b'\n') + 1, len(b[ls:off].decode('utf-8')) + 1
```

| offset | (line, column) |
| --- | --- |
| 29 | (4, 1) |
| 49 | (4, 21) |
| 50 | (5, 1) |

**Established:** the finding is `4:1`–`4:21` and the fix edit ends at `5:1`, i.e. the edit includes the
newline and its SARIF end position lands on column 1 of the next line — exactly the shape SARIF §3.30.2
NOTE 6 describes for "an entire line together with its trailing newline sequence". The direct half-open
conversion needs no special case for it. Every worked example in the freeze uses these numbers.

---

## 6. Validator availability for RRF-FINAL

```sh
$ which check-jsonschema jq python3 xmllint
check-jsonschema not found
/opt/homebrew/bin/jq
/opt/homebrew/bin/python3
/usr/bin/xmllint
$ python3 -c "import jsonschema"
ModuleNotFoundError: No module named 'jsonschema'
$ uv --version
uv 0.11.28
```

**Established:** `jq`, `xmllint`, and `python3` are present; the JSON-schema validators are not, but
`uv run --with check-jsonschema` and `uv run --with jsonschema` reach them without a new system
dependency. RRF-FINAL's independent-parser gate (`notes` §8.2) is therefore runnable as specified.

---

## 7. External sources quoted in the freeze

| Claim | Source |
| --- | --- |
| `endColumn` is exclusive; region defaults; text/binary independence; `columnKind` **SHALL** | SARIF 2.1.0 OASIS Standard, `https://docs.oasis-open.org/sarif/sarif/v2.1.0/os/sarif-v2.1.0-os.html`, §§3.8.1, 3.13.2, 3.13.4, 3.14.27, 3.20.21, 3.30.2, 3.30.4, 3.30.6, 3.30.8, 3.30.9, 3.58.6 |
| GitHub workflow-command escaping (`escapeData`/`escapeProperty`) | `actions/toolkit`, `packages/core/src/command.ts` |
| `col`/`endColumn` cannot be set when `line != endLine` | `astral-sh/ruff`, `crates/ruff_db/src/diagnostic/render/github.rs`, citing `astral-sh/ruff#22074` |
| "There is no official specification for the JUnit XML file format" | `testmoapp/junitxml` README |

The spec HTML was downloaded and flattened to text locally for exact quotation rather than read through
a summarizer; every SARIF quotation in the freeze is verbatim from that text.
