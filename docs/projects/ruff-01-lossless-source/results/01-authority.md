# RLS-SPEC — Freeze the lossless-source contract

Claim: **RLS-SPEC**. Design output is `notes/01-source-authority.md`; this note records the
commands, raw evidence, and what changed while executing.

- Base commit: `5f68c97479b967668371e5c48c4775b268afcd84`
- Toolchain: `leanprover/lean4:v4.32.0` (target and experiment pinned identically)
- Machine: Apple M4 Pro, 24 GiB, Darwin 25.5.0 arm64
- Evidence transcript: `evidence/01-round-trip.txt` (102 lines, `cases=13 failures=0`)

## What was built

`experiments/lossless-source/` is a self-contained oracle that shares no module with `LeanFmt`, so a
production regression cannot mask a parser fact.

- `RoundTrip.lean` — parse-level oracle. Walks `header :: commands ++ [eoi]`, records every leaf's
  `SourceInfo`, and builds two independent reconstructions: one from raw source slices
  `source[pos, endPos)`, one from the parser's own atom value / ident `rawVal`. Compares each
  against both the on-disk bytes and `raw.crlfToLf`, and separately checks that leaf spans are
  contiguous from byte 0.
- `ProbePlugin.lean` — a module linter that runs the same reconstruction from inside the compiler,
  where the token table contains the file's own syntax declarations.
- `fixtures/{Trivia,Tokens,Syntax}.lean` — tracked adversarial modules.
- `run.sh` — generates the byte-exotic fixtures (they cannot be tracked as `.lean` without breaking
  the repository's native source boundary), then asserts a declared outcome per fixture.

Exit codes are the harness contract: `0` round-trip, `1` parsed but reconstruction diverged, `3`
parser rejected the file. This keeps "Lean rejects these bytes" distinguishable from "Lean accepts
these bytes but the trivia record does not reconstruct them", which is the distinction the whole
contract turns on.

## Commands

```sh
experiments/lossless-source/run.sh              # 13 cases, 0 failures
LEAN_NUM_THREADS=1 lake build                   # 30 jobs, success
lake exe lean-fmt-tests                         # module-artifact tests passed
tests/compiler/run.sh                           # compiler facet tests passed
tests/boundary/run.sh                           # native module and dependency boundary passed
git diff --check                                # clean
python .claude/skills/lean-plan/scripts/check_stack.py <stack>    # 3 prompts, 0 warnings
python .claude/skills/lean-plan/scripts/write_next.py --check <stack>  # matches 01-authority
```

## Measurements

Round-trip against the string the parser was actually given (`raw.crlfToLf`), all fixtures:

| fixture | raw B | norm B | normalized? | leaves | slice RT | token RT | coverage |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `Trivia.lean` | 369 | 369 | no | 24 | true | true | contiguous from 0 |
| `Tokens.lean` | 757 | 757 | no | 139 | true | true | contiguous from 0 |
| `Crlf` | 31 | 28 | **yes** | 8 | true | true | contiguous from 0 |
| `NoFinalNewline` | 37 | 37 | no | 8 | true | true | contiguous from 0 |
| `TrailingSpace` | 45 | 45 | no | 8 | true | true | contiguous from 0 |
| `HeaderOnly` | 7 | 7 | no | 2 | true | true | contiguous from 0 |
| `CommentOnly` | 38 | 38 | no | 2 | true | true | contiguous from 0 |
| `TrailingBlankLines` | 45 | 45 | no | 8 | true | true | contiguous from 0 |
| `Exit` | 56 | 56 | no | 8 | **false** | **false** | contiguous, stops at 36 |

Every accepted fixture has `synthetic=0 missing=0`. `Crlf` round-trips the normalized string but
*not* the on-disk bytes (`slice_roundtrip_raw=false`). `Exit` stops at byte 36 of 56.

Parser rejections (exit 3), i.e. outside "accepted source":

- `Tabs` — `tabs are not allowed; please configure your editor to expand them`
- `Bom` — `expected token` at 1:0
- `LoneCr` — `isolated carriage returns are not allowed`

Compiler-plugin probe, same fixtures, elaborated token table:

| fixture | source B | linter cmds | rebuilt B | command span | uncovered prefix |
| --- | --- | --- | --- | --- | --- |
| `Trivia` | 369 | 4 | 361 | `[8, 369)` | 8 |
| `Tokens` | 757 | 16 | 749 | `[8, 757)` | 8 |
| `Syntax` | 1023 | 17 | 1002 | `[21, 1023)` | 21 |

`rebuilt = source - prefix` exactly in all three; the uncovered prefix is exactly the header text
(`module\n\n` = 8; `module\n\nimport Lean\n\n` = 21); the span always ends at end-of-file; all leaves
`original`.

Control: `fixtures/Syntax.lean` builds cleanly under the probe but **fails to parse** under a
parse-only token table built from its imports, with errors at every use of its own syntax
(`my_local_cmd` 13:14, `⋄` 22:28, `run_mycat` 39:14).

Product-level identity check, run by converting the tracked `tests/compiler/LocalSyntax.lean`
fixture to CRLF (130 bytes on disk) and rebuilding its artifact:

```
artifact.sourceBytes = 122
artifact.source      = c2fedb2cf69fbcb94145c13c4030de5f377ffcc66c823d570c82c03dcf6e0ff1
commands             = 3
```

122 = 130 − 8, exactly the eight `\r` bytes removed by `crlfToLf`. The fixture was restored
afterwards; `git diff` on it is empty. `commands = 3` for a file with a header plus three commands
independently confirms that the linter array excludes both the header and `eoi`.

## Decisions changed during execution

1. **The oracle was wrong twice before it was right, and both failures are findings.**
   `importModules` defaults to `loadExts := false`, which silently yields a token table without even
   `Init`'s tactics; parsing diverges rather than erroring. And `importModules (loadExts := true)`
   may run only once per process, which forced one-process-per-file — independently reproducing
   execution-core-v2's "process exit is the reclamation boundary" finding.
2. **The contract is defined over the normalized string, not the file.** This was not the starting
   assumption. `mkInputContext` normalizes CRLF by default, so no compiler-produced offset indexes
   the on-disk bytes. The schema therefore records `lineEndings` plus both a raw and a normalized
   digest, and reconstruction of the file is invariant 4 rather than a direct claim about ranges.
3. **The plugin alone cannot be lossless.** Module linters never receive the header. The schema
   records it explicitly rather than assuming `cmds` covers the file.
4. **`#exit` is a third class**, neither accepted-and-lossless nor rejected. The schema gained
   `terminalStop` and a verbatim `tail`.
5. **Fixture placement.** Byte-exotic fixtures are generated by `run.sh` rather than tracked,
   because `tests/boundary/run.sh` requires every tracked `.lean` to begin with `module` and a
   CRLF or BOM fixture cannot. This is deliberate and documented in the script.

## Defect found in shipped code

Not repaired here — `RLS-SPEC` is a specification prompt and `notes/01-source-authority.md` §8 hands
the repair to `RLS-IMPL`:

- `CompilerPlugin.lean` digests `(← getFileMap).source` (normalized) while `Application.lean:624`
  digests `IO.FS.readFile` output (raw). Every CRLF file is therefore a permanent silent artifact
  miss, degrading to the exact-frontend fallback. Cost and identity defect, not wrong output.
- Inside `analyzeExact`, `projectCommands` produces ranges into the normalized string while
  `runRules source` produces ranges into the raw string. `validCommand` only checks
  `stop <= sourceBytes`, so a mismatched range validates silently.
- `Analysis.lean`'s `collectCommands` drops every terminal command. That is correct for `eoi`
  (measured: carries no bytes) but silently drops `#exit` and everything after it.

## Files changed

- `experiments/lossless-source/{lakefile.lean,lean-toolchain,lake-manifest.json,README.md,run.sh}`
- `experiments/lossless-source/{RoundTrip.lean,ProbePlugin.lean}`
- `experiments/lossless-source/fixtures/{Trivia,Tokens,Syntax}.lean`
- `docs/projects/ruff-01-lossless-source/notes/01-source-authority.md`
- `docs/projects/ruff-01-lossless-source/evidence/01-round-trip.txt`
- `docs/projects/ruff-01-lossless-source/results/01-authority.md`
- `docs/projects/ruff-01-lossless-source/state/{current.md,next.md}`

No production module changed.

## Remaining uncertainty

- The `leading`/`trailing` split point between adjacent tokens is uncharacterized; only the
  concatenation is proven exact. The schema stores both verbatim so the contract does not depend on
  it, but a formatter asking "which comment precedes this token" will need the fact. Deferred to
  `RLS-IMPL` as a consumer question.
- `Command.import` as a terminal command was not exercised.
- No size, encode/decode time, plugin overhead, or extraction memory measurement exists yet. The
  token stream is strictly larger than `CommandShape` and the roadmap requires bounding that cost;
  `RLS-FINAL` owns it. Nothing in this prompt licenses a claim that the new schema is affordable.
- The corpus is nine synthetic fixtures plus three tracked modules. It is adversarial by
  construction, not representative; the frozen mathlib sample has not been run against the oracle.
