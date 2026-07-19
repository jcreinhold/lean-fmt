# RDF-SPEC first-hand probes — fusion, non-subsumption, FMT001 corruption

Environment: `LEAN_NUM_THREADS=1 lake build` clean (42 jobs); product binary
`.lake/build/bin/lean-fmt`. All probes `--no-cache`. Fixtures are real project modules built with the
`leanFmtArtifact` facet.

## Fixtures (byte-visible)

- `tests/check/Findings.lean` = `module\n\ndef findingValue : Nat := 1  \n` — trailing 2 spaces before the
  final newline (FMT001), final newline present.
- `tests/check/Layout.lean` = `namespace     Alpha` (5 spaces) — layout-dirty, lint-clean.
- Temporary `tests/check/StringWs.lean` (added to `CheckFixtures.roots`, built, then removed; lakefile
  restored) = `module\n\ndef stringWsValue : String := "alpha   \n  beta"` — 3 trailing spaces **inside**
  the multi-line string literal after `alpha`, and **no final newline**. String value is
  `"alpha   \n  beta"`.

## Probe 1 — fusion: `format` applies the FMT001 source fix

`lean-fmt format --root . --no-cache tests/check/Findings.lean`
→ body prints `def findingValue : Nat := 1` (trailing whitespace **gone**); `findings=1 changed=1`.
`format` composed FMT001's trim onto the reflow.

## Probe 2 — non-subsumption (trailing ws): printer alone leaves it

`format --no-cache --select FMT013 tests/check/Findings.lean` and `format --no-cache --ignore FMT001 …`
→ both `findings=0 changed=0`: with FMT001 deselected, canonical text equals the input **including** the
trailing whitespace. The printer does not trim it.

## Probe 3 — StringWs findings

`check --json --no-cache tests/check/StringWs.lean` → FMT001 (`safe` fix) **and** FMT002 (`safe` fix)
both fire. FMT001's fix range falls inside the string literal's bytes.

## Probe 4 / 4b — default `format` corrupts the string AND adds the newline

`format --json --no-cache tests/check/StringWs.lean` →
- `formatted = 'module\n\ndef stringWsValue : String := "alpha\n  beta"\n'`
- input was `'…"alpha   \n  beta"'` (no final `\n`).

Two changes, both from composed rule fixes: the 3 spaces **inside** the string literal are deleted
(FMT001 — a silent value change from `"alpha   \n  beta"` to `"alpha\n  beta"`), and a final newline is
appended (FMT002). `findings=2 changed=1`.

## Probe 5 — non-subsumption (both), printer alone

`format --json --no-cache --select FMT013 tests/check/StringWs.lean` (FMT001+FMT002 OFF) →
`changed: False`, `formatted: None`. Canonical text equals the input **exactly**: interior trailing
whitespace preserved and **no** final newline appended. The printer subsumes neither.

## Probe 6 — the FMT001 corruption is written; the validator misses it

`fix --root . --no-cache tests/check/StringWs.lean` → `tests/check/StringWs.lean: fixed`,
`written=1 rejected=0`. On-disk bytes after the write:
`'module\n\ndef stringWsValue : String := "alpha\n  beta"\n'` — the corrupted string value is published.
The output re-elaboration validator does not reject it, because the corrupted file still elaborates (it is
a valid string literal, only a different value). Pre-existing FMT001 soundness defect, confirmed
end-to-end.

## Conclusion (frozen in `results/01-spec.md`)

Today's clean `format` output for trailing-whitespace and final-newline comes **entirely** from
FMT001/FMT002 fixes composed onto the canonical patch (`renderCanonicalText`'s `runSourceRules`,
`Application.lean:379-382`), never from the printer. Once `format` stops applying rule fixes (RDF-IMPL), a
fix-free `format` would regress ws/newline unless the formatter takes ownership as layout — and the
FMT001 in-string corruption must not survive the move. Resolution: RDF-LAYOUT moves ws/newline into the
printer (trivia-only trim + guaranteed final newline, sound by construction) and retires FMT001/FMT002.
