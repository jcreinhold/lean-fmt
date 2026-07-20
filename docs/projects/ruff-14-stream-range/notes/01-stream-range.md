# Stream identity and range expansion — the RSF-SPEC freeze

Owner: `ruff-14-stream-range` prompt `01-contract` (claim `RSF-SPEC`).
Prerequisites re-read live for this freeze: `LeanFmt/Cli.lean`, `LeanFmt/Application.lean`,
`LeanFmt/Service.lean`, `LeanFmt/Project.lean`, `LeanFmt/Printer.lean`, `LeanFmt/Doc.lean`,
`LeanFmt/Comments.lean`, `tests/modes/run.sh`, `tests/boundary/run.sh`.

Following the `*-SPEC` convention (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC), this
prompt ships **no production Lean interface, config key, or CLI surface.** It ships this freeze, the
characterization test that pins its central claim (`LeanFmtTest.lean`, layout suite), and the probe
behind it.

---

## 1. What exists today

Measured, not assumed (`evidence/01-stream-range-baseline.md`):

| Form | Today |
| --- | --- |
| `lean-fmt format -` | `unknown option: -`, exit 2 |
| `lean-fmt format --stdin-filename X.lean` | `unknown option: --stdin-filename`, exit 2 |
| `lean-fmt format --range 0:10` | `unknown option: --range`, exit 2 |

`parseFileArgs` treats any argument starting with `-` as an option (`Cli.lean:129-131`), so all three
forms are rejected before they reach the driver. There is no stdin surface and no range surface. The
raw-bytes-to-stdout path `ruff-11d` deliberately left unbuilt when it removed the
`=== path (N bytes) ===` dump is still unbuilt, which is what this stack is for.

**The "layout source map" the roadmap tells RSF-IMPL to reuse is not populated in production.**
`Doc.mark` and the `Mark` record exist and render correctly (`Doc.lean:78-79, 125-131, 210`), and
`Doc.render` returns `String × Array Mark` — but `Printer` emits no `.mark` anywhere
(`grep -n '\.mark' LeanFmt/Printer.lean` is empty), and `Printer.format` calls `renderText`, the
accessor that discards the map (`Printer.lean:2148-2152`). Every existing consumer of `mark` is a unit
test. This is an interface obligation RSF-IMPL inherits, named here rather than left to be invented
mid-implementation — the same shape as `ruff-13`'s notice-channel widening (`ruff-13`
`notes/01-discovery.md` §8.2).

---

## 2. CLI forms

```
lean-fmt {check|format|diff|fix} - --stdin-filename PATH [OPTIONS]
                                  [--range START:STOP | --range-lines L:C-L:C]
```

`-` is a **file target**, not an option: it says "the one target's bytes arrive on stdin". It is
accepted only as the sole target.

**`--stdin-filename PATH` is required whenever `-` is used.** This is stricter than `ruff format -`,
which falls back to built-in defaults, and the strictness is the point. Since `ruff-13` the effective
configuration is a per-file fact resolved from the file's location in the tree (`ruff-13`
`notes/01-discovery.md` §5; `SourceTarget.config`, `Project.lean:24-32`). A buffer with no location has
no closest config, no `line-width`, and no module identity for `Lean.ModuleSetup`. Serving it built-in
defaults would answer the same bytes differently depending on whether they arrived by path or by pipe,
silently — **stdin must not become a second configuration path.** The roadmap's stop rule ("reject
stdin requests that cannot establish exact project identity when selected features require it") reads
as *always* in this product, because every mode consumes the effective configuration and the two
rendering modes additionally demand `.semantic`, which needs the exact Lake setup
(`Application.lean:1119`, `RulePlan.demandedTier`).

Rejected, exit 2, one deterministic message each:

| Form | Message |
| --- | --- |
| `-` without `--stdin-filename` | `stdin requires --stdin-filename to establish project identity` |
| `--stdin-filename` without `-` | `--stdin-filename is valid only with the - stdin target` |
| `-` alongside another file target | `- must be the only target` |
| `--range` / `--range-lines` without `-` | `--range is valid only with the - stdin target` (§7) |
| both range forms at once | `--range and --range-lines are mutually exclusive` |

`--stdin-filename PATH` **need not exist on disk.** It supplies identity, not content; an editor
formatting an unsaved buffer has no file yet. This is the one place the frozen behavior cannot reuse
`Project.snapshotTarget`, which calls `realPath` and `readFile` (`Project.lean:115-136`). RSF-IMPL owes
a sibling that takes bytes and a path and does **not** touch the filesystem for content, while keeping
every gate `snapshotTarget` applies:

- root containment (`insideRoot`), reported as `selected file is outside the project root: <arg>`;
- `.lean` extension, `selected file is not a Lean source: <arg>`;
- the `.lake` floor, `selected file is inside the Lake build directory: <arg>`.

Per `CLAUDE.md` ("Path errors name the caller's own argument"), every one of these names the string the
caller passed to `--stdin-filename`, not a resolved buffer. Gate 1 (`.lake`) is not liftable by the
stdin form any more than by an explicit path — that was `ruff-13`'s closed write-safety defect and it
stays closed.

---

## 3. Position encoding

Two forms, one internal encoding.

- **`--range START:STOP`** — half-open `[START, STOP)` **byte offsets into the normalized source**,
  `raw.crlfToLf`. This is the primary form and the only one that reaches the driver.
- **`--range-lines L:C-L:C`** — 1-based line, 1-based **codepoint** column, converted to byte offsets
  at the CLI boundary. Start is inclusive, stop is exclusive.

Three decisions and their reasons:

1. **Normalized coordinates, not raw bytes.** `CLAUDE.md` already requires this of every
   compiler-produced offset, finding, and digest, because `Parser.mkInputContext` normalizes before it
   assigns any position. A caller holding raw-byte offsets into a CRLF file will be off by one per
   preceding line — stated as a consequence, not hidden. The stdin form makes this cheap to get right:
   the caller sends the bytes, and `LosslessSource.normalize` runs on exactly what it sent.
2. **Codepoint columns, not UTF-16.** It matches `Doc.width`'s frozen policy (`Doc.lean:88-96`, a
   compromise `RLC-SPEC` recorded rather than hid) and it is what a human reads off an editor status
   bar. UTF-16 is what LSP needs, and `ruff-17-lsp` owns that negotiation; it converts to bytes at its
   own boundary. Two *entry* encodings converging on one *internal* encoding is not two encodings.
3. **Half-open.** Every range in this product already is: `SourceRange`, `Finding.range`, `Mark`.

Malformed input is exit 2 with the offending text quoted: a non-numeric field, a missing `:`, `STOP <
START`, or `STOP` past the byte size of the received source.

---

## 4. The layout-unit lattice, and what makes a boundary safe

The roadmap requires a boundary that is **reflow-stable**, not merely parse-safe. That property is not
a property of commands. It is a property of `Doc.fits`, which walks the *tail* of the work list
(`Doc.lean:165-188`): a `group` at the end of a unit measures itself against whatever follows it, so it
can be rebroken by text outside the unit.

Exactly one thing stops that walk: a `verbatim` holding a newline, which `fits` treats like `hard`
(`Doc.lean:174-176`). Measured directly (`evidence/01-unit-independence-probe.lean`, margin 10):

```
newline-terminated trivia: solo="aaaa bbbb\n"
  short-tail prefix stable = true      with short tail = "aaaa bbbb\nx"
  long-tail  prefix stable = true      with long  tail = "aaaa bbbb\nyyyyyyyyyyyyyyyy"
same-line trivia (space)  : solo="aaaa bbbb "
  short-tail prefix stable = false     with short tail = "aaaa\nbbbb x"
  long-tail  prefix stable = false     with long  tail = "aaaa\nbbbb yyyyyyyyyyyyyyyy"
```

A **one-character** tail is enough to rebreak the unit before it when that unit does not end in a
newline. This is pinned by a characterization test in the layout suite so RSF-IMPL cannot drift off it.

### 4.1 The units

The normalized source tiles into three kinds of unit, all of which already exist:

| Unit | Extent | Produced by |
| --- | --- | --- |
| header | `[0, headerStop)` | `Printer.headerDoc` — laid out as one unit |
| command | each `CommandSpan.extent` | `Tree.commands` (`Printer.lean:159-191`) |
| tail | `[terminalStop, normalizedBytes)` | `Tree.document` — carried verbatim |

Command extents "tile `[headerStop, terminalStop)` exactly once and touch" (`Printer.lean:146-158`),
which `structurallyValid` already requires. So the three kinds tile the whole file, gap-free, and every
byte belongs to exactly one unit.

### 4.2 Expansion rule (frozen)

Given a requested normalized byte range `[a, b)`:

1. Select every unit whose extent intersects `[a, b)`.
2. For an **empty** request (`a == b`), select the single unit whose extent contains `a`; if `a` is
   exactly a unit boundary, select the unit that *starts* there; if `a == normalizedBytes`, select the
   tail.
3. Extend forward while the last selected unit's extent does not end with trivia containing a newline
   (§4's condition). In practice this fires only for same-line commands — `def a := 1 def b := 2` —
   and it terminates at the tail, which is the file end.
4. The selection is a contiguous run of units, because the units tile and step 1 takes a hull.

The **actual range** is the hull of the selected units' extents. It may span lines the caller did not
edit — that is the roadmap's stated consequence of reflow, and step 3 is where it comes from.

### 4.3 Comment ownership at boundaries

Frozen by measurement, and it is counter-intuitive enough to state plainly.

`RLC-SPEC` measured Lean's trivia split on the parser: `nonempty_leading=0`, `comment_in_trailing=6`,
`verdict=trailing-greedy` (`ruff-02-layout-core/results/01-design.md:55-69`). Everything between two
tokens — a same-line trailing comment, a blank line, and a stack of comments written *above* the next
declaration — lives in the **preceding** token's trailing run. `Tree.commands` inherits that: a
command's extent runs from where the previous one ended to the end of its own last token's trailing
run, so **trivia between two commands belongs to the earlier command.**

**This is extent ownership, not comment attachment, and they genuinely differ.** `tests/layout/run.sh`
prints `own-line comments lead the next token`, which reads as the opposite. It is not: that line
describes `Comments.partitions`, which re-splits a raw trailing run at `Comments.splitPoint` — the
first newline — so an own-line comment is attributed to the *next* token for placement purposes
(`Comments.lean:94-110`). `Tree.commands` does not use that split; it uses `tokenEnd`, the end of the
raw trailing run (`Printer.lean:129-132`). The extent is the coarser of the two, and the extent is what
a range expands to. Both statements hold; a reader comparing them needs to know which question each
answers, so RSF-IMPL must not "reconcile" them by changing either.

Consequences a caller can rely on:

- A range covering only `def foo` does **not** include the comment block written above `def foo`. That
  comment belongs to the previous command's unit and is left byte-identical. Minimal disturbance, which
  is what a range request wants.
- A range covering that comment block **does** pull in the preceding command, because the comment is
  inside its extent. The reported actual range says so.
- A same-line trailing comment (`def x := 1  -- why`) is inside `def x := 1`'s own unit.

---

## 5. Output shape

The streamed result for a range is

```
normalized[0, unitStart)  ++  rendered(selected units)  ++  normalized[unitEnd, normalizedBytes)
```

denormalized back to the received source's line-ending form on the way out
(`LosslessSource.denormalize`), so a CRLF buffer streams back CRLF.

**Documented boundary whitespace** — the roadmap's "byte-identical except explicitly documented
boundary whitespace" is exactly two things and nothing else:

1. **The final newline.** `Printer.format` ends in `normalizeEof`, a whole-file property (FMT002).
   Frozen: it applies **only when the selected units include the tail**, i.e. when the request reaches
   the file end. A mid-file range neither adds nor removes the trailing newline.
2. **Trivia inside the selected units.** Trailing whitespace and blank-line runs within a selected
   unit's own extent are canonicalized, because they are that unit's bytes. Nothing outside `unitEnd`
   is touched.

**Full-range equivalence** falls out: `--range 0:<byteSize>` selects every unit including the tail, so
the prefix and suffix are empty and `normalizeEof` applies — the output is `Printer.format`'s, byte for
byte. `RSF-FINAL` tests this rather than assuming it.

**Idempotence**: re-running the same *reported actual* range over the output must be a fixed point.
Re-running the *requested* range need not be, because the actual range may be wider; `RSF-FINAL` tests
the former.

### 5.1 The reported range and source map

`format -` with a range writes the formatted bytes to stdout. The actual range and source map ride
`--json` (the deterministic channel this product already uses for machine consumers), not the byte
stream — the byte stream stays exactly the file so a pipe consumer needs no framing:

- `requestedRange`, `actualRange` — normalized byte ranges;
- `sourceMap` — the `Mark` array for the selected units, each `{source, output}` byte range.

Without `--json`, stdout is bytes only. This is why §2 forbids a file-target range: `format` on a file
publishes in place, and the roadmap's first bullet explicitly forbids reintroducing a file-target
stdout escape hatch.

---

## 6. Diagnostics and exit codes

Findings and diagnostics ride the existing `RunReport`/`FileReport` shapes with `path` set to the
`--stdin-filename` value; text mode prints them to **stderr** so stdout carries only the stream.

| Mode | stdout | Exit 0 | Exit 1 | Exit 2 |
| --- | --- | --- | --- | --- |
| `format -` | formatted bytes | streamed | broken/rejected | infrastructure, usage |
| `format --check -` | (nothing) | clean | would change, broken/rejected | " |
| `diff -` | unified diff | clean | would change, broken/rejected | " |
| `check -` | (nothing) | no findings | findings, broken/rejected | " |
| `fix -` | fixed bytes | streamed | broken/rejected | " |

The rule is the file-target rule (`Cli.lean:239-246`) with one substitution: a stdin mode that emits
its result **is** the writer, so `format -` and `fix -` exit 0 having streamed, exactly as `format`/`fix`
exit 0 having published. `--check` and `diff` stay previews and keep the CI code. Nothing about the
existing table changes.

A buffer that does not elaborate is `broken` and streams **nothing** — not partial bytes, not the
input. Silence plus exit 1 is unambiguous; echoing the input would let a broken buffer be written back
over a good file by a shell redirect.

Invalid UTF-8 on stdin is exit 2, `stdin is not valid UTF-8`.

---

## 7. Cache and write policy

Frozen, and each clause has a reason rather than a precedent:

1. **stdin never writes source.** `--stdin-filename` is an identity, never a destination. The
   publication path (`publishAtomic`) is not reachable from the stdin form at all — not guarded, absent.
2. **stdin never reads or writes persistent result-cache entries.** Not by defaulting `--no-cache` but
   unconditionally: a cache entry is keyed on a source digest bound to a file on disk, and unsaved bytes
   have no disk state to bind. This is the same rule `CLAUDE.md` already states for the service
   ("Unsaved bytes share `Application.ExactRun` with batch fallback, never disk-state evidence or
   persistent cache entries").
3. **stdin gets the service's resource envelope.** One `withExactRun`, a fresh bounded child per
   request, the `--max-memory` aggregate limit. Prompt 02's stop rule states this; it is the same
   `ExactRun` the service and batch fallback use, so it is not a second execution path.
4. **`--range` requires `-`.** §2. A partial in-place write would be a new write surface with new
   stale-check semantics and no named caller; `ruff-17-lsp` is the consumer that would want file-target
   ranges, and it goes through the service.

---

## 8. Interface obligations RSF-IMPL inherits

Named here so they are not invented mid-implementation:

1. **Populate the source map.** `Tree.document` must wrap each unit in `.mark`: the header at
   `[0, headerStop)`, each command at its `CommandSpan.extent`, the tail at
   `[terminalStop, normalizedBytes)`.
2. **One render, two accessors.** `Printer.format` keeps its `String` signature as the façade; a
   sibling returns `String × Array Mark`. Not a second printer path (prompt 02's stop rule) — the same
   `Doc.render` call, with the map kept instead of dropped.
3. **A filesystem-free target constructor.** §2: bytes + path in, `SourceTarget` out, every
   `snapshotTarget` gate applied, no `realPath`/`readFile` on the content.
4. **Range expansion belongs below the CLI.** `LeanFmt.Cli` parses `--range` into a byte range and
   renders the report. Unit selection, expansion, the actual range, and the splice are
   `LeanFmt.Application`'s, beside the other lifecycle it owns.

---

## 9. Open questions, deliberately left open

- **UTF-16 positions.** Deferred to `ruff-17-lsp`, which owns the LSP position-encoding negotiation.
- **File-target ranges.** Out of scope by §7.4; would need a partial-write stale-check design.
- **A range whose units are all header.** The header is laid out by `headerDoc?`, which *refuses* on any
  parser message and returns the source bytes (`Printer.lean:2116-2126`). A header-only range on a file
  with a recovering header therefore reports an actual range and changes nothing. Correct, and worth a
  fixture in `RSF-FINAL`.
- **Very large single commands.** A file that is one enormous command has one unit, so every range
  expands to the whole file. Expected, not a defect; `RSF-FINAL` records it if the frozen sample has one.
