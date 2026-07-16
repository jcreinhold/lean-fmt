---
kind: state
first_unresolved: 03-acceptance
---

# Current state

The lossless-source contract is frozen in `notes/01-source-authority.md` and backed by a
toolchain oracle (`experiments/lossless-source/`) that shares no module with `LeanFmt`. Its
external prerequisite stack `execution-core-v2` is verified and its live implementation still
matches recorded state.

`LeanFmt/LosslessSource.lean` is live. `CommandShape` is removed, `ModuleArtifact` carries one
`LosslessSource`, and both producers reach it through `ModuleArtifact.ofParsedModule`, which
`tests/check/run.sh` checks by asserting the exact frontend's artifact equals the plugin's
byte-for-byte. All three defects `RLS-IMPL` inherited are fixed and measured.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-authority | RLS-SPEC | verified | — |
| 02-implementation | RLS-IMPL | verified | RLS-SPEC |
| 03-acceptance | RLS-FINAL | planned | RLS-IMPL |

## Known evidence

- `SourceInfo.original` leading/trailing substrings are the only trivia authority; comments and
  whitespace are not tree nodes. Concatenating `leading ++ token ++ trailing` over the ordered leaf
  walk reproduces the parsed string byte-for-byte, contiguous from byte 0, on every accepted
  fixture (13 cases, 0 failures). The parser's atom value is the literal source text, verified
  across unicode/ASCII token spellings, escaped identifiers, string/char/raw literals, and
  hex/binary/octal/scientific numerals.
- `Parser.mkInputContext` defaults to `normalizeLineEndings := true`, so every compiler-produced
  byte offset indexes `raw.crlfToLf`, not the on-disk bytes. A CRLF fixture measured
  `raw_bytes=31 normalized_bytes=28`, round-tripping the normalized string and not the file.
- Module linters never receive the header or `eoi`. Probe measurements show the uncovered prefix is
  exactly the header text (8, 8, and 21 bytes) and that command spans always end at end-of-file,
  with `synthetic=0 missing=0` even for macro-heavy files.
- A parse-only token table cannot parse a file that declares its own syntax; the elaborated
  environment is authoritative. `importModules` defaults to `loadExts := false`, which silently
  yields a wrong token table, and may run with `loadExts := true` only once per process.
- Lean rejects tabs, a leading BOM, and isolated `\r`; those are outside "accepted source".
  `#exit` is accepted but leaves an unparsed tail (measured: parsing stopped at byte 36 of 56).
- Artifact identity is normalized identity. A module linter is handed already-normalized
  `fileMap.source` and cannot observe the file's bytes, so `lineEndings`, `rawBytes`, and
  `rawDigest` were removed from the schema frozen in `notes/01-source-authority.md` §6; a field only
  one of the two mandated producers can fill is two schemas in one structure. Consumers hold the
  file and recover line endings themselves. Details in `notes/02-projection-interface.md`.
- Derived field-name JSON measured 12.21x the source (8692 B for 714 B); the shipped fixed-shape
  array encoding measures 3.93x (2798 B), 28 B per token against 114 B. The artifact is
  `O(tokens + nodes + distinct kinds)`, not `O(source bytes)`: a 34-byte module measures 29x because
  the schema strings and two digests dominate.
- The CRLF defect is fixed end to end: a 734-byte CRLF file records `normalizedBytes = 714` and is
  accepted by the `.olean` payload, the sidecar facet, and the registered no-build Lake job.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.
- The three defects `RLS-IMPL` inherited from `results/01-authority.md` are fixed and measured in
  `results/02-implementation.md`: the CRLF identity mismatch, the mixed coordinate systems inside one
  artifact, and the dropped `#exit` terminal and tail.
- No size, time, or RSS profile of the new schema exists beyond three fixtures, all under 1 KB.
  Nothing yet supports a claim that the token stream is affordable on a real module. `RLS-FINAL`
  owns that profile, and it is the largest open risk in this stack.
- No consumer reads the `nodes` table yet. It costs about as much as the token table and is 2.4x its
  size; the roadmap requires syntax boundaries, so it ships, but its granularity is unmeasured.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
