---
kind: state
first_unresolved: 02-implementation
---

# Current state

The lossless-source contract is frozen in `notes/01-source-authority.md` and backed by a
toolchain oracle (`experiments/lossless-source/`) that shares no module with `LeanFmt`. Its
external prerequisite stack `execution-core-v2` is verified and its live implementation still
matches recorded state. No production module has changed yet.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-authority | RLS-SPEC | verified | — |
| 02-implementation | RLS-IMPL | planned | RLS-SPEC |
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

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.
- `RLS-IMPL` inherits three recorded defects in shipped code, detailed in `results/01-authority.md`:
  the plugin digests normalized text while the application digests raw bytes, so every CRLF file is
  a permanent silent artifact miss; `analyzeExact` mixes normalized command ranges with raw rule
  ranges inside one artifact and validation cannot detect it; and `collectCommands` drops `#exit`
  and its tail along with the harmless `eoi`.
- No size, time, or memory measurement of the new schema exists. The token stream is strictly larger
  than `CommandShape`; nothing yet supports a claim that it is affordable.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
