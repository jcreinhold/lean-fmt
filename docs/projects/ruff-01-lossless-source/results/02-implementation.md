# RLS-IMPL — the lossless projection in production

`CommandShape` is gone. `LeanFmt/LosslessSource.lean` (455 lines) is the private projection and
codec; `ModuleArtifact` now carries one `LosslessSource` and nothing else that could disagree with
it. Both mandated producers reach it through a single function, and every consumer authenticates it
against the file it read.

The interface comparison and the two decisions that changed during implementation are in
`notes/02-projection-interface.md`.

## Commands

```sh
LEAN_NUM_THREADS=1 lake build                     # 32 jobs, clean
LEAN_NUM_THREADS=1 lake build lean-fmt-tests artifactExtractor
./.lake/build/bin/lean-fmt-tests                  # lean-fmt module-artifact tests passed
tests/compiler/run.sh                             # lean-fmt compiler facet tests passed
tests/check/run.sh                                # lean-fmt check integration tests passed
tests/modes/run.sh                                # lean-fmt product mode integration tests passed
tests/scale/run.sh                                # complete-selection and module-evidence passed
tests/service/run.sh                              # editor service integration tests passed
tests/boundary/run.sh                             # native module and dependency boundary passed
git diff --check                                  # clean
```

## Measurements

### Wire format

Derived field-name `ToJson` was measured first and rejected. `tests/compiler/LocalSyntax.lean`,
714 normalized bytes, 31 tokens, 75 nodes, 22 distinct kinds:

| encoding | artifact | ratio | per token | per node |
| --- | --- | --- | --- | --- |
| derived field-name objects | 8692 B | 12.21x | 114 B | 54 B |
| fixed-shape arrays | 2798 B | 3.93x | 28 B | 13 B |

Ratio against source is not the compactness claim. The artifact is `O(tokens + nodes + distinct
kinds)`; fixed schema strings and two digests dominate a small module:

| module | source | artifact | ratio | tokens | nodes | kinds |
| --- | --- | --- | --- | --- | --- | --- |
| `Clean` | 34 B | 1001 B | 29.44x | 6 | 23 | 10 |
| `Findings` | 38 B | 1161 B | 30.55x | 6 | 23 | 10 |
| `LocalSyntax` | 712 B | 2798 B | 3.93x | 31 | 75 | 22 |

`LeanFmtTest` therefore bounds per-element cost (`< 1024 + 40 * (tokens + nodes)`), which the
rejected encoding fails and the shipped one passes with margin.

### The CRLF defect is fixed, end to end

`tests/compiler/LocalSyntax.lean` converted to CRLF, then built and consumed through all three
paths:

| measurement | value |
| --- | --- |
| bytes on disk | 734 |
| `normalizedBytes` recorded | 714 |
| `verify-plugin-artifact` (`.olean` payload) | accepted |
| `verify-facet-artifact` (sidecar + content hash) | accepted |
| `verify-official-facet` (registered no-build Lake job) | accepted |
| `FMT001` range | `{517, 519}`, normalized coordinates |

Every one of these was a permanent silent miss before: the plugin digested 714 normalized bytes and
the application digested 734 raw bytes, so the identities could never match for any CRLF file.

### Both producers agree byte-for-byte

`tests/check/run.sh` asserts `fallback == integrated` on the full JSON: the exact frontend's
artifact and the compiler plugin's artifact for `LocalSyntax` are identical. They reach
`ModuleArtifact.ofParsedModule` with the same arguments, so this is structural, not a coincidence
that could drift.

## Decisions changed during execution

1. **Identity is normalized-only.** `01-source-authority.md` §6 froze `lineEndings`, `rawBytes`, and
   `rawDigest` into the schema. A module linter is handed already-normalized `fileMap.source` and
   cannot observe the file's bytes, so the plugin cannot produce those fields; a schema only one
   producer can fill is two schemas. They are gone. `LineEndings`/`normalize`/`denormalize` remain as
   the codec, used by `Application` to read into the one coordinate system and publish back.

2. **Hand-written array wire format.** Derived JSON measured 12.2x the source, contradicting the
   roadmap's "compact". `Trivia`, `Token`, and `Node` are hand-encoded; decoders are total and reject
   any other shape.

3. **The artifact's findings are canonical.** `SemanticAnalysis.ofEnvelope?` recomputed
   `runRules source true` on the consumer side, discarding the artifact's findings and hardcoding
   `true` over the module's traced `leanFmt.trailingWhitespace`. It now uses `artifact.findings`.
   Recomputing was a second opinion about a module this process never elaborated.

4. **`ModuleArtifact.ofParsedModule` is the only producer.** Previously each producer built the
   record inline, which is how their identity halves drifted apart in the first place.

## Defects found and fixed

- **CRLF silent miss** (inherited, recorded in `results/01-authority.md`): fixed and measured above.
- **Mixed coordinate systems in one artifact** (inherited): `analyzeExact` digested and ran rules on
  raw bytes while recording normalized command ranges. `runRules` now takes the normalized string,
  documented as its contract; the raw-CRLF branch inside `trailingWhitespace` was dead under that
  contract and is removed.
- **`#exit` and its tail dropped** (inherited): `collectCommands` discarded every terminal command.
  It now returns the terminal separately, and `terminalStop` records where the parsed region ends.
- **Edits were prepared against raw bytes**: introduced by the migration and caught before it
  shipped. Findings index normalized text, so `prepareFile` prepares the patch against normalized
  text and `PreparedFile.output` denormalizes to the file's own form; `publishAtomic` still
  stale-checks against the raw bytes it read. The `diff` preview compares normalized against
  normalized, so a CRLF file no longer reads as every line changed.
- **Consumer ignored traced configuration**: see decision 3.

## Files changed

- `LeanFmt/LosslessSource.lean` (new), `LeanFmt/ArtifactModel.lean`, `LeanFmt/Rules.lean`,
  `LeanFmt/CompilerPlugin.lean`, `LeanFmt/Analysis.lean`, `LeanFmt/ArtifactStore.lean`,
  `LeanFmt/Semantic.lean`, `LeanFmt/Application.lean`, `lakefile.lean`
- `LeanFmtTest.lean`, `tests/check/run.sh`, `tests/modes/run.sh`,
  `tests/compiler/LocalSyntax.lean`
- `AGENTS.md` — the normalized-coordinate rule is now a standing constraint.

`SourceRange` moved from `ArtifactModel` to `LosslessSource`, which owns it; `ArtifactModel` imports
it. `artifactSchema` is bumped to `v2` so a `v1` payload left in an `.olean` misses rather than
decodes.

## Tests added

`testLosslessSource` covers 13 structural rejections (stale schema, gaps, overlap, inverted spans,
trivia past the next token, a stream short of the terminal, a terminal past the end, a header past
the terminal, nonexistent node/kind/parent, fabricated positions) plus the CRLF acceptance, wrong
source, truncated source, and the JSON round trip. `testStore` adds stale-`v1`, wrong-module,
wrong-source, and out-of-range-finding rejections.

`checkProjection` runs against real compiler output in `verify-plugin-artifact` and
`verify-facet-artifact`. It is the test that has teeth: `structurallyValid` proves the spans tile but
is content-blind, so `checkProjection` walks the projection independently, recovers each trivia run's
start by contiguity, slices the source at every recorded boundary, and checks that each run contains
the form its kind names and that header + tokens + tail reconstructs the file byte-for-byte.

`tests/compiler/LocalSyntax.lean` gained the coverage the prompt names: line comments, nested block
comments, a module doc, a doc comment, a Unicode string with an emoji, a guillemet identifier, and
Greek identifiers — alongside the file-local `syntax` and the `macro_rules` quotation it already had.

The enriched fixture confirms `01-source-authority.md`'s trivia classification in shipped output:
the module doc is a **token** spanning `[12, 230]` whose trailing trivia is
`[[0,232],[1,310],[0,311],[2,402],[0,404]]` — whitespace, a line comment, whitespace, a nested block
comment, whitespace. Doc comments are leaves; only whitespace and the two comment forms are trivia.

## Remaining uncertainty

- No size, time, or RSS profile exists beyond the three fixtures above, all under 1 KB. The token
  stream is `O(tokens + nodes)` and 3.93x source on the largest one, but nothing here supports a
  claim about a real module. `RLS-FINAL` owns the profile.
- `nodes` is 2.4x `tokens` on `LocalSyntax` and costs about as much as the token table. No consumer
  reads the node table yet; the roadmap requires syntax boundaries, so it ships, but whether the full
  flattened tree is the right granularity is unmeasured.
- `structurallyValid` rejects any token that is not `.original`. Every accepted fixture parses to
  `original` leaves throughout, consistent with `01-source-authority.md`'s `synthetic=0 missing=0`
  measurement, but that is measured on fixtures, not proven for all accepted source. A module whose
  parsed commands carry a synthetic leaf would be an artifact miss and fall back to the exact
  frontend — correct, but silently slower.
- The `kinds` table is interned per module and is 604 B of the 2798 B `LocalSyntax` artifact. Kind
  strings repeat across modules and nothing shares them.
