# Lossless source authority

This note freezes the lossless-source contract for `RLS-SPEC`. Every claim below is backed by a
toolchain experiment recorded in `results/01-authority.md` and reproducible with
`experiments/lossless-source/run.sh`. Where an earlier assumption in this repository turned out to
be wrong, the note says so rather than quietly restating the corrected version.

Toolchain: `leanprover/lean4:v4.32.0`.

## 1. What the compiler actually owns

`Lean.SourceInfo` (`Init/Prelude.lean:4827`) is the only authority for trivia:

```
| original (leading : Substring.Raw) (pos : String.Pos.Raw)
           (trailing : Substring.Raw) (endPos : String.Pos.Raw)
| synthetic (pos endPos : String.Pos.Raw) (canonical : Bool)
| none
```

Comments, doc comments, and whitespace are *not* separate tree nodes. They live inside the
`leading` and `trailing` substrings of atoms and identifiers. There is no comment node to find and
no gap to interpret.

Measured consequence: for every accepted fixture, concatenating
`leading ++ tokenText ++ trailing` across the ordered leaf walk of
`header :: commands ++ [eoi]` reproduces the parsed string **byte-for-byte**, with leaf spans
contiguous from byte 0 and no gaps or overlaps. This holds for nested block comments, doc comments,
trailing comments with no following command, blank-line runs, and files with no commands at all.

Both candidate token payloads round-trip: the raw source slice `source[pos, endPos)` and the
parser's own `Syntax.atom` value / `Syntax.ident` `rawVal`. The atom value is the literal matched
source text, not a canonicalized token name — verified across `→` versus `->`, `fun` versus `λ`,
`«escaped identifier»`, string escapes, raw strings, character literals, and hex/binary/octal/
scientific numerals (`fixtures/Tokens.lean`, 139 leaves, all `original`).

**Authoritative:** `SourceInfo.original` leading/trailing substrings and token payloads of the
parsed, pre-expansion command syntax.

## 2. Positions index the normalized string, not the file

This is the finding that most changes the design, and it contradicts what the current code assumes.

`Lean.Parser.mkInputContext` (`Lean/Parser/Extension.lean:459`) takes `normalizeLineEndings := true`
by default and parses `text.source.crlfToLf`. Production uses this exact constructor
(`LeanFmt/Analysis.lean`). Therefore **every `String.Pos.Raw` in every `SourceInfo` indexes the
CRLF-normalized string.** The parser never sees a `\r` that was part of a `\r\n`.

Measured on a CRLF fixture: `raw_bytes=31 normalized_bytes=28`, round-trip against the normalized
string true, round-trip against the on-disk bytes false.

This already breaks the shipped product. `LeanFmt/CompilerPlugin.lean` records
`source := (← getFileMap).source` — the *normalized* text — while `LeanFmt/Application.lean:624`
computes `Digest.ofString (← IO.FS.readFile sourcePath)` over the *raw* bytes. Building the tracked
`LocalSyntax` fixture converted to CRLF produced an artifact recording `sourceBytes = 122` for a
file that is 130 bytes on disk: exactly the eight `\r` bytes `crlfToLf` removed. Since
`ArtifactStore.readFacet?` and `Semantic.ofEnvelope?` both require
`artifact.sourceBytes == source.utf8ByteSize` against raw bytes, **every CRLF file is a permanent,
silent artifact miss today.** It degrades to the exact-frontend fallback rather than misreporting,
so it is a cost and correctness-of-identity defect, not a wrong-output defect.

Worse for `RLS-IMPL`: inside `analyzeExact` the two halves of one artifact use different coordinate
systems. `projectCommands` yields ranges into the normalized string while `runRules source` yields
ranges into the raw string, and `validCommand` only bounds-checks `stop <= sourceBytes`, so a
mismatched range validates silently.

**Contract:** the projection is defined over the normalized string. Exactly one normalization step
is permitted, it happens where the file is read, and the recorded source identity, all byte ranges,
and all rule inputs refer to that one string. Reconstructing the on-disk file additionally requires
the recorded line-ending form; see §6.

## 3. The plugin cannot see the header, and that is structural

`Lean.Elab.Command.ModuleLinter.run : Array Syntax → CommandElabM Unit` is invoked by
`runModuleLinters cmds` (`Lean/Elab/Command.lean:273`) from `runLintersAsync`, which fires when
`Parser.isTerminalCommand stx` holds. `Lean/Language/Lean.lean:749` accumulates `cmds.push stx`
*before* parsing the next command, so the array passed to a module linter contains:

- every non-terminal command, in order;
- **not** the module header (`module`, `prelude`, `import` lines), which `Parser.parseHeader`
  consumes before command parsing begins; and
- **not** the terminal `eoi` command.

Measured with a probe module linter (`experiments/lossless-source/ProbePlugin.lean`) on the same
fixtures:

| fixture | source bytes | linter commands | rebuilt bytes | command span | uncovered prefix |
| --- | --- | --- | --- | --- | --- |
| `Trivia.lean` | 369 | 4 | 361 | `[8, 369)` | 8 |
| `Tokens.lean` | 757 | 16 | 749 | `[8, 757)` | 8 |
| `Syntax.lean` | 1023 | 17 | 1002 | `[21, 1023)` | 21 |

In every case `rebuilt_bytes = source_bytes - uncovered_prefix`, the uncovered prefix is exactly the
header text, and the command span ends exactly at end-of-file. All leaves are `original`:
`leaves_synthetic = 0`, `leaves_missing = 0`, including for the macro-heavy fixture.

Two facts follow. Trailing trivia of the last real token always reaches end-of-file — `mkEOI`
(`Lean/Parser/Module.lean:114`) constructs the `eoi` atom with empty leading and trailing at the end
position, so it contributes nothing and dropping it loses nothing. And a projection built only from
what a module linter is handed **cannot** be lossless: it is missing the header by construction.

**Contract:** the projection records the header explicitly. The plugin has `getFileMap`, so the
header text is recoverable as the prefix `[0, firstCommandStart)`; it must be captured deliberately,
not assumed to be covered by `cmds`.

## 4. Only the elaborated environment can parse the file

A token table assembled from a file's imports does not contain that file's own `syntax`,
`notation`, `declare_syntax_cat`, or `macro_rules` declarations. Those live in environment
extensions and only exist after the declaring command elaborates.

Measured: `fixtures/Syntax.lean` is a valid module that builds cleanly under the compiler probe (17
commands, 149 original leaves, full coverage to byte 1023). The same file under a parse-only token
table built from its imports **fails to parse**, with errors at each use of the file's own syntax
(`my_local_cmd`, the `⋄` notation, `run_mycat`). The failure is not graceful degradation; it is a
different, wrong tree.

A related trap: `importModules` defaults to `loadExts := false`. With that default the token table
lacks even `Init`'s tactics, and parsing diverges silently rather than erroring at the boundary. The
oracle only became correct once it passed `loadExts := true`.

**Contract:** syntax-input claims come from the compiler plugin or an exact frontend that
elaborates. This restates `AGENTS.md`'s "do not call superset parsing exact" as a measured fact, and
it is why the artifact must be produced from inside the compiler rather than reconstructed beside
it.

## 5. The boundary of "accepted source"

The roadmap's contract is "round-trip every accepted UTF-8 source". Measured classification of the
adversarial corpus:

| class | fixtures | obligation |
| --- | --- | --- |
| accept | trivia, tokens, CRLF, no final newline, trailing spaces, header-only, comment-only, trailing blank lines | full round-trip of the normalized string |
| reject | tabs, UTF-8 BOM, isolated `\r` | none: Lean does not accept these bytes |
| truncate | `#exit` | round-trip requires an explicit uninterpreted tail |

Lean rejects tabs (`tabs are not allowed`), a leading BOM (`expected token` at 1:0), and isolated
carriage returns (`isolated carriage returns are not allowed`). These are outside the contract and
must be reported as ordinary rejections, never silently reformatted.

`#exit` is the one case that is accepted yet not covered. `Parser.isTerminalCommand`
(`Lean/Parser/Module.lean:119`) is true for `Command.exit`, `Command.import`, and `Command.eoi`, and
the frontend stops at the first one. Measured: for a 56-byte file, parsing stopped at byte 36 and
the remaining 20 bytes were never parsed and carry no trivia, while the file still compiles.

**Contract:** the projection records a terminal position and the uninterpreted tail after it
verbatim. The tail is never reformatted and never rule input.

## 6. Wire schema

Versioned as `lean-fmt.lossless-source.v1`. This supersedes `CommandShape` (kind + optional range),
which is a lossy projection that cannot round-trip and whose ranges silently mix coordinate systems
(§2).

```
LosslessSource
  schema        : String        -- "lean-fmt.lossless-source.v1"
  mainModule    : String
  lineEndings   : LineEndings   -- lf | crlf, the form observed on disk
  rawBytes      : Nat           -- on-disk size, before normalization
  rawDigest     : Digest        -- digest of the on-disk bytes
  normalizedBytes  : Nat        -- size of the string the parser saw
  normalizedDigest : Digest     -- digest of that string; every range below indexes it
  header        : SourceRange   -- [0, firstCommandStart), never empty
  tokens        : Array Token   -- ordered, contiguous, covering [0, terminalStop)
  terminalStop  : Nat           -- end of parsed region; < normalizedBytes only for `#exit`
  tail          : String        -- uninterpreted bytes after terminalStop; usually ""

Token
  leading   : String            -- trivia before the token, verbatim
  text      : String            -- literal source text of the token
  trailing  : String            -- trivia after the token, verbatim
  kind      : String            -- parser kind of the innermost enclosing node
  parent    : Nat               -- index into `nodes`, for parent/child structure
  start     : Nat               -- byte offset of `text` in the normalized string
```

Invariants, all checkable on consumption without the frontend:

1. `tokens[0].start - tokens[0].leading.utf8ByteSize == 0` — coverage starts at byte 0.
2. For each adjacent pair, `prev.trailingStop == next.leadingStart` — contiguous, no gaps, no
   overlaps.
3. `concat (leading ++ text ++ trailing) ++ tail` equals the normalized string, and its digest
   equals `normalizedDigest`.
4. Re-applying `lineEndings` to that string reproduces the on-disk bytes, whose digest equals
   `rawDigest` and whose length equals `rawBytes`.
5. Every range is within `[0, normalizedBytes]` and `start <= stop`.
6. `header.stop == tokens[headerTokenCount].start` and `header.start == 0`.

Invariant 4 is what makes the roadmap's "byte-for-byte before formatting" claim true of the *file*
rather than only of the parser's view of it. Invariants 1–3 are the losslessness proof and are
exactly what the oracle already checks.

`LineEndings` is deliberately an enum, not a per-line record. Lean rejects isolated `\r` (§5), so a
file's line endings are uniformly `\n` or uniformly `\r\n`; a mixed file is already not accepted
source. If a future toolchain accepts mixed endings, invariant 4 fails loudly rather than
reconstructing the wrong bytes.

## 7. Rejected alternatives

- **Keep `CommandShape` and infer trivia from gaps between command ranges.** Rejected: the prompt
  forbids it without proof, and §1 shows there is no need — the parser already owns exact trivia.
  Inference would also be unable to place a comment inside a command, which `fixtures/Trivia.lean`
  contains.
- **Store byte ranges into the on-disk file.** Rejected by §2: no such coordinate system exists in
  the parser's output. Any range the compiler produces indexes the normalized string. Recording raw
  offsets would require a position mapping whose only purpose is to undo a normalization the
  projection can simply record.
- **Serialize `Lean.Syntax` directly.** Rejected: it exposes frontend objects to product callers,
  which the roadmap forbids, and it is unbounded in size. The token stream carries the same trivia
  with a flat, versionable shape.
- **Reconstruct the header by re-running `Parser.parseHeader` on consumption.** Rejected: it puts a
  parser on the consumption path, and the header is precisely where `import` ordering and
  search-path precedence live, which `AGENTS.md` requires be preserved exactly. The producer sees it
  for free via `getFileMap`.
- **Digest only the normalized string and drop `rawDigest`/`lineEndings`.** Rejected: two files
  differing only in line endings would share an identity, so a CRLF file could hit a cache entry
  produced from its LF twin and be rewritten with the wrong endings. Write safety requires raw
  identity.
- **Normalize line endings on write to make CRLF files go away.** Rejected: `fix` would rewrite
  every line of a CRLF file, which is not a formatting decision the user asked for and violates the
  roadmap's exactness constraint.
- **Drop the `eoi` command.** Accepted, but only because §3 measured that it carries no bytes. The
  current `Analysis.lean` drops it via `isTerminalCommand`, which is correct for `eoi` and *wrong*
  for `#exit`: it also silently drops the `exit` command and its tail.

## 8. Consequences for `RLS-IMPL`

1. Read the file once, normalize once, record `lineEndings`/`rawDigest`/`normalizedDigest` at that
   point, and pass only the normalized string downstream. This removes the raw/normalized mixing in
   `Analysis.lean` and `CompilerPlugin.lean`.
2. Capture the header prefix explicitly in the plugin; `cmds` never contains it.
3. Handle `#exit` as a terminal with a recorded tail rather than as `eoi`.
4. `runRules` must take the normalized string, so both artifact halves share one coordinate system.
5. Validation on consumption checks invariants 1–6 and treats every failure as an ordinary miss.

## 9. Remaining uncertainty

- The `leading`/`trailing` split point between adjacent tokens was not characterized; only their
  concatenation was proven exact. The schema stores both verbatim, so the contract does not depend
  on where the split falls, but a formatter that reasons about "the comment before this token" will
  need that fact. Deferred to `RLS-IMPL`, where it is a consumer question.
- Only `Command.exit` and `Command.eoi` were exercised as terminals. `Command.import` is also
  terminal and reaching it means a misplaced `import`, which is a parse error in a `module` file;
  this was not measured.
- Artifact size, encode/decode time, plugin overhead, and extraction memory are unmeasured. The
  token stream is strictly larger than `CommandShape`, and the roadmap requires bounding that cost.
  `RLS-FINAL` owns it.
