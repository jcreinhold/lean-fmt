# RRF-FINAL — acceptance

Claim: **RRF-FINAL** — parse SARIF/JUnit/JSON outputs using independent validators, inspect GitHub
commands and concise paths, test Unicode and failures, and benchmark large synthetic reports.

Freeze: `notes/01-report-formats.md` (§12 records how its §11 open questions closed). Scale evidence:
`evidence/03-report-scale.md`. Suite: `tests/reporting/run.sh` (64 assertions, up from 58).

## Commands

```sh
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake build lean-fmt-tests
lake exe lean-fmt-tests
lake exe lean-fmt-tests report-bench
tests/reporting/run.sh
tests/check/run.sh
tests/modes/run.sh
tests/suppression/run.sh
tests/stream/run.sh
tests/syntax/run.sh
tests/compiler/run.sh
tests/lossless/run.sh
tests/scale/run.sh
tests/service/run.sh
tests/discovery/run.sh
tests/boundary/run.sh
git diff --check
uv run --with pyyaml .claude/skills/lean-plan/scripts/check_stack.py <workspace> --structural  # from kan-proofs
uv run --with pyyaml .claude/skills/lean-plan/scripts/write_next.py <workspace> --check        # from kan-proofs
```

## Results read

| Check | Result |
| --- | --- |
| `lake build` | `Build completed successfully` |
| `lake build lean-fmt-tests` | `Build completed successfully` |
| `lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `lean-fmt-tests report-bench` | 24 rows; see `evidence/03-report-scale.md` |
| `tests/reporting/run.sh` | `lean-fmt reporting format tests passed` (64 assertions, 0 failures) |
| `tests/check/run.sh` | `lean-fmt check integration tests passed` |
| `tests/modes/run.sh` | `lean-fmt product mode integration tests passed` |
| `tests/suppression/run.sh` | `lean-fmt suppression acceptance tests passed` |
| `tests/stream/run.sh` | `failures=0` |
| `tests/syntax/run.sh` | `lean-fmt syntax-tier rule integration tests passed` |
| `tests/compiler/run.sh` | `lean-fmt compiler facet tests passed` |
| `tests/lossless/run.sh` | `lean-fmt lossless projection corpus passed` |
| `tests/scale/run.sh` | `lean-fmt complete-selection and module-evidence tests passed` |
| `tests/service/run.sh` | `lean-fmt editor service integration tests passed` |
| `tests/discovery/run.sh` | `lean-fmt configuration discovery acceptance tests passed` |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `git diff --check` | no output |
| structural checker | `OK: 3 prompt(s), 0 warning(s), no errors.` |
| `write_next.py --check` | `OK: state/next.md matches first_unresolved=none` |

## The roadmap gate RRF-IMPL could not meet

*"Benchmark large synthetic reports."* `lake exe lean-fmt-tests report-bench` renders synthetic reports
of 100 / 1,000 / 10,000 / 100,000 findings — spread across 1 / 2 / 20 / 200 files — through all six
formats. Full table in `evidence/03-report-scale.md`; the summary:

| Format | 100,000 findings | growth over the last decade |
| --- | --- | --- |
| `text` | 9.52 ms | 8.1× |
| `json` | 108.75 ms | 10.1× |
| `concise` | 311.41 ms | 10.2× |
| `github` | 1521.54 ms | 11.4× |
| `sarif` | 2297.23 ms | 10.3× |
| `junit` | 3231.36 ms | 10.4× |

Ten times the report costs about ten times the milliseconds in every format. `Lean.Json.pretty` over a
50 MB SARIF log is in that path, which is precisely what `evidence/02-renderer-cost.md` recorded as
still owed. Whole process: 10.61 s, 740 MiB peak, 0 swap — inside the envelope.

**The measurement corrected an assumption.** RRF-IMPL suspected SARIF's pretty-printer as the scale
risk. It is not. `text` — the one format that resolves no positions — is 33× faster than `concise` at
100,000 findings *while emitting more bytes*, and `json` serializes 14 MB with no lookups faster than
`concise` serializes 7 MB with 200,000 of them. The `PositionIndex` lookups dominate, not the
serializers. Nothing needs changing at any report size a Lean project can produce, but the note is
recorded rather than left as a wrong intuition in the stack.

## The four open items RRF-IMPL handed over

1. **The synthetic benchmark** — discharged above.
2. **SARIF `uri` percent-encoding** — implemented. `uriPathEncode` encodes to RFC 3986 §3.3 `pchar`
   plus `/`, over UTF-8 bytes, and is applied to both a result's `uri` and the `%SRCROOT%` root (a
   checkout under `~/My Projects/` would otherwise have broken every URI in the run, not one). Two
   cases: the escaped bytes, and — the half that matters — an independent `urllib.parse` round-trip
   asserting no delimiter leaked into a fragment or query and that unquoting recovers
   `src/my dir/Ä#b%c.lean` exactly. A self-consistent escaper passes the first and fails the second.
3. **`helpUri`** — added, after establishing the fact that blocked it: `docs/rules/` holds a page for
   every live code, import family included. The assertion is not that a string is present but that the
   file every emitted `helpUri` names exists in this repository, so a renamed rule page fails the suite
   rather than shipping a dead link.
4. **`Lean.Json.pretty` byte stability** — deliberately left unpinned, with the reasoning recorded in
   the freeze (§12) rather than only here. Byte stability is a promise `--output-format json` makes and
   `tests/check/run.sh` enforces; that path uses `compress`, not `pretty`. SARIF and JUnit promise parse
   stability, which independent parsers check. A byte golden over `pretty` would turn a layout this
   stack never contracted into a toolchain tripwire. Accepted risk, named: a reflow that keeps the
   document valid passes silently — the correct outcome for a schema-defined format.

Plus the fifth, cheap one: the `format` pseudo-rule id is now asserted against `lean-fmt rules --json`
rather than argued from the `FMT` namespace.

## New coverage

`tests/reporting/run.sh` gained 6 assertions, 58 → 64. **`results/02-renderers.md` said "50 cases",
which was wrong**: it counted `check`/`contains` call sites, and several sit inside `for` loops over
the six formats, so the suite emitted 58 assertions at that commit. Corrected there as well as here,
because a count nobody re-derived is exactly the kind of number that rots.

- **URI encoding** (2) — escaped bytes, and the independent-parser round-trip.
- **`helpUri`** (1) — every emitted link resolves to a file in the repository.
- **Pseudo-rule id** (1) — no collision with the live registry.
- **Astral-plane columns** (1) — `𝔘` is 4 bytes, 2 UTF-16 code units, and 1 codepoint, so one fixture
  separates all three encodings at once. The reported column is 34 where a byte column would be 37 and
  a UTF-16 column 35. `Unicode.lean`'s 2-byte characters distinguish codepoints from bytes but cannot
  distinguish codepoints from UTF-16 — nothing in the BMP can — so this closes a gap the existing
  Unicode coverage structurally could not.
- **GitHub property round-trip** (1) — the suite already asserted the escaped bytes; this applies the
  documented inverse (`%25`, `%3A`, `%2C`, `%0D`, `%0A`) and asserts recovery of
  `weird,path:with%signs/A.lean`. An escaper that is merely self-consistent passes the old case and
  fails this one.

## Independent validators, as the prompt requires

No format is checked only by our own string matching where a real consumer exists:

| Format | Validator | What it is |
| --- | --- | --- |
| `sarif` | `check-jsonschema` against the vendored SARIF 2.1.0 schema | schema conformance |
| `sarif` | `python3 -c` conformance block | the `SHALL`s the schema does not encode (`columnKind`, region purity, descriptor coverage, `executionSuccessful`) |
| `sarif` | `urllib.parse` | URI reference validity and round-trip |
| `junit` | `junitparser` | an independent consumer reading back suites, cases, result types, counts |
| `junit` | `xmllint --noout` | well-formedness under a hostile path |
| `json` | `tests/check/run.sh` golden `cmp` | byte-for-byte against a report recorded *before* this stack shipped a renderer |
| `github` | `python3` unescaper | the documented inverse of the escaping contract |

## Files changed

| File | Change |
| --- | --- |
| `LeanFmt/Cli.lean` | `uriPathEncode`; applied at `sarifLocation` and `rootUri`; `helpUri` in `sarifRuleDescriptor` |
| `LeanFmtTest.lean` | `import all LeanFmt.Cli`; `section ReportBench` with `benchLine`, `benchFile`, `mergePositions`, `reportBench`; `report-bench` dispatch |
| `tests/reporting/run.sh` | +14 cases: URI encoding, `helpUri`, pseudo-rule id, astral-plane column, GitHub round-trip |
| `docs/projects/ruff-15-reporting/evidence/03-report-scale.md` | new — the synthetic scale benchmark |
| `docs/projects/ruff-15-reporting/notes/01-report-formats.md` | §12 — how §11's open questions closed |

## Remaining uncertainty

- **The scale fixture is uniform.** Every synthetic line is the same 47 bytes, so the benchmark does not
  probe a pathological source — one enormous line, or findings clustered at the end of a very large
  file — where the `PositionIndex` *build* rather than its lookups could behave differently. The build
  is one forward pass, O(source bytes) by construction, and it is setup rather than measured work in
  `reportBench`. Named rather than claimed covered.
- **`Lean.Json.pretty` reflow across toolchains is unpinned by decision**, recorded above and in §12.
  If a later stack ever promises byte-stable SARIF, that decision reopens.
- **`uriPathEncode` percent-encodes conservatively but not maximally.** It leaves the RFC 3986
  sub-delims (`!$&'()*+,;=`) and `:`/`@` unencoded because §3.3 permits them in a path segment. A
  consumer that mis-parses a legal `pchar` would still break; that is the consumer's defect, and the
  round-trip case documents which characters we rely on it to handle.
