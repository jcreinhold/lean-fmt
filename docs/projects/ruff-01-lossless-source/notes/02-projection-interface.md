# The lossless projection interface

`RLS-IMPL`'s plan requires designing the interface twice before implementing. This note records
both designs, the comparison, and the resulting change to the schema frozen in
`01-source-authority.md` §6.

## The two designs

**Design A — self-contained token stream.** Each token stores its trivia and payload as strings:
`leading : String`, `text : String`, `trailing : String`. Reconstruction is
`concat (leading ++ text ++ trailing) ++ tail`. This is what `01-source-authority.md` §6 froze.

**Design B — offsets into the digest-matched normalized source.** Each token stores spans into the
normalized string: where its text starts and stops, and where its trivia runs end. No source text is
stored. Reconstruction is a slice of the source the consumer already holds.

| axis | A (text) | B (offsets) |
| --- | --- | --- |
| caller knowledge | artifact alone suffices | needs the normalized source |
| invariants hidden | "concat equals source" | "spans tile `[0, terminalStop)`" |
| checking cost | O(bytes), rebuilds the string | O(tokens), integer comparisons |
| error surface | text can disagree with the file while staying internally consistent | any disagreement fails the digest or the tiling |
| exactness | direct | derived from digest identity |
| cache identity | normalized digest | normalized digest (identical) |
| critical path | decode allocates ~1× source in strings plus JSON unescaping | decode allocates a flat integer array |
| memory enforceability | artifact is O(source bytes) | artifact is O(token count) |

## Selected: B

The apparent advantage of A is that the artifact stands alone. No consumer wants that. Every
consumer already reads the source and must digest-match it before trusting the artifact
(`Application.lean`, `ArtifactStore.readFacet?`, `Semantic.ofEnvelope?`), so "needs the normalized
source" costs a caller nothing it was not already doing. A therefore pays a full copy of the source,
in the most expensive possible encoding, to avoid a dependency the caller already has.

B is also the stronger design on error surface, which is the reverse of the intuition. Under A a
corrupted artifact whose text was mutated consistently still reconstructs *something*; detecting it
requires rebuilding the string and comparing. Under B the token spans must tile `[0, terminalStop)`
exactly — checkable in one integer pass, without touching a byte — and the bytes themselves are
authenticated once by `normalizedDigest`. Corruption cannot survive both.

The roadmap demands "one exact, compact representation" and requires measuring artifact size. A is
strictly larger than the source it describes. B is proportional to token count with no text at all.

### This does not weaken the round-trip claim

The prompt's stop rule forbids relying on `Syntax.getRange?` alone, and forbids inferring comments
from gaps without proving round-trip behavior. B does neither:

- It does not use `getRange?`. It uses `SourceInfo.original`'s own `leading`/`trailing` substring
  bounds, which are the parser's recorded trivia, not a derived hull.
- It does not infer from gaps. There are no gaps: `01-source-authority.md` §1 measured that the
  spans tile the file contiguously from byte 0, and `structurallyValid` now *enforces* that tiling
  rather than assuming it.
- Round-trip behavior was proven first, in `RLS-SPEC`, by an oracle that shares no module with the
  product.

Losslessness under B is the conjunction of two enforced facts: the spans tile the whole parsed
region, and the bytes they index hash to `normalizedDigest`. That is a stronger guarantee than A's,
because A's reconstruction can be self-consistent and still wrong about the file.

## Schema changes against `01-source-authority.md` §6

`Token` no longer carries `leading`, `text`, or `trailing` strings. It carries spans, plus classified
trivia runs. `tail` is no longer stored as a string; it is the span `[terminalStop, normalizedBytes)`.
`headerStop`, `terminalStop`, and invariants 1–6 stand unchanged — only their representation is
cheaper to check.

### Identity is normalized-only: `lineEndings` and raw identity are gone

§6 froze `lineEndings`, `rawBytes`, and `rawDigest` into the schema. Implementation showed they
cannot be there. A module linter is handed `fileMap.source`, which `Parser.mkInputContext` already
normalized (§2); that position cannot observe the file's bytes, so the plugin cannot produce those
three fields at all. Since `RLS-IMPL` requires the projection be produced *from both* exact analysis
and the plugin, a field only one producer can fill is either a lie or an `Option` that is always
`none` from one side — two schemas in one structure. The two producers would then disagree on exactly
the CRLF files that miss today.

So `LosslessSource` records `normalizedBytes` and `normalizedDigest` and nothing about the file.
Nothing is lost: every consumer holds the file, so it recovers line endings itself. `LineEndings`,
`normalize`, and `denormalize` remain as the codec — `Application` uses them to read a file into the
one coordinate system and to publish a formatted result back in the file's own form.

This is what actually fixes the recorded CRLF defect. The old code had the plugin digest normalized
text and the application digest raw bytes; now both sides digest normalized text, and the only place
raw bytes appear is reading and writing files.

### The wire format is arrays, not derived field-name objects

Derived `ToJson` measured **12.2x the source** on the local-syntax fixture (8692 bytes for 714) —
`{"kind":"whitespace","stop":4}` spends 24 of 29 bytes restating the schema. That contradicts the
roadmap's "compact" and the claim above that B is the smaller design. `Trivia`, `Token`, and `Node`
are the only things whose count grows with a file, so each is hand-encoded as a fixed-shape array:
the same fixture measures **3.93x** (2798 bytes), 28 bytes per token and 13 per node against 114 and
54. The decoders are total and reject any other shape; a projection that fails to decode is an
ordinary miss. `LosslessSource` itself keeps named fields — there is one per file.

Ratio against source is not the compactness claim and the test does not assert it: a 34-byte module
measures 29x because two digests and the schema strings dominate. The artifact is `O(tokens + nodes
+ distinct kinds)`, and that is what the bound in `LeanFmtTest` checks.

## Trivia classification

`01-source-authority.md` §6 did not say how "comments, doc comments, whitespace ... are
distinguished". Reading `Lean/Parser/Basic.lean:563-588` settles it, and it is simpler than expected:

- **Doc comments are not trivia.** `Lean/Parser/Basic.lean:584` states outright that `/--` and `/-!`
  "are actual tokens". They are syntax nodes and are distinguished for free by node kind.
- Trivia is exactly three things: Unicode whitespace runs (`Char.isWhitespace`), `--` line comments
  running to but not including the newline, and `/- -/` block comments, which nest.
- Tabs and isolated `\r` are errors inside the trivia lexer itself, which is why
  `01-source-authority.md` §5 measured them as rejections.

So `Trivia` is `{ kind : whitespace | lineComment | blockComment, stop : Nat }`, and the runs tile
each trivia span. The scanner mirrors `whitespace`'s grammar over a span Lean has already delimited;
it never decides *where* trivia is, only what is inside it. `tests/lossless` pins it against the
fixtures that carry nested and adjacent comment forms.

## Rejected within B

- **Store `leadingStart` per token.** Redundant: contiguity makes it the previous token's trailing
  stop, and storing it invites the two to disagree. The first token's leading starts at 0.
- **Store each trivia run's start.** Same reason; runs tile their span, so a stop per run suffices.
- **Intern token kinds as raw strings per token.** Kind strings repeat heavily across a file. The
  projection interns them into a `kinds` table and stores indices.
- **Derive trivia classification lazily on the consumer.** Rejected: it would put a scanner on the
  consumption path and let two consumers disagree. The producer classifies once.
