# Evidence 01 — today's `format` is a non-writing stdout preview

First-hand characterization captured on the live binary (commit at FIP-SPEC), `LEAN_NUM_THREADS=1
lake build lean-fmt Layout:leanFmtArtifact`, `app=$(lake -q query lean-fmt --text)`. The fixture is
the tracked `tests/check/Layout.lean`, whose only defect is layout (`namespace␣␣␣␣␣Alpha`), no rule
finding.

## Text output — `$app format tests/check/Layout.lean`

```
=== tests/check/Layout.lean (63 bytes) ===
module

namespace Alpha

def layoutValue : Nat := 1

end Alpha
=== end tests/check/Layout.lean ===
mode=format files=1 findings=0 changed=1 written=0 broken=0 rejected=0 withheld_unsafe=0 suppressed=0 infrastructure_failures=0
```

Exit code **1**. The whole canonical body is dumped to stdout between `=== <path> (<N> bytes) ===`
and `=== end <path> ===` framing (`Cli.lean:163-171`, the `"format"` arm of `renderText`).

## JSON output — `$app format --json tests/check/Layout.lean`

```json
{"broken":0,"changed":1,"files":[{"diagnostics":[],"diff":null,"findings":[],
"formatted":"module\n\nnamespace Alpha\n\ndef layoutValue : Nat := 1\n\nend Alpha\n",
"path":"tests/check/Layout.lean","status":"would-format","suppressed":0,"withheldRedundant":0,
"withheldUnsafe":0,"written":false}],"findings":0,"infrastructureFailures":[],"mode":"format",
"rejected":0,"suppressed":0,"withheldRedundant":0,"withheldUnsafe":0,"written":0}
```

Status `would-format`; `formatted` carries the full canonical text; `written:false`; top-level
`written:0`. Exit **1**.

## No write

`md5 -q tests/check/Layout.lean` is byte-identical before and after (`ff258ff9…`). `format` never
touches the file — the canonical text lives only in the report's `formatted` field and the stdout
dump. `fix` is the sole writer today (`fixFile`, `Application.lean:889-920`, ends in
`publishAtomic`; `previewFile .format`, `Application.lean:876-880`, only sets `formatted`).

## Clean file — `$app format tests/check/Clean.lean`

```
mode=format files=1 findings=0 changed=0 written=0 broken=0 rejected=0 ...
```

Exit **0**, no framing block (no `formatted`). An already-canonical file is `clean`.

## Exit-code source

`reportExitCode` (`Cli.lean:211-214`): infra → 2; `broken>0 || rejected>0` → 1; else `mode != .fix
&& changed>0` → 1; else 0. So today `format` (not `.fix`) exits **1** whenever it would change a
file — the CI-preview code. `fix` exits 0 on a change because of the `mode != .fix` guard. FIP-SPEC
freezes the flip: writing `format` must join `fix` on the 0-on-change side; `format --check` keeps
the current 1-on-change CI code.
</content>
