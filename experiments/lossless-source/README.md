# lossless-source

Toolchain experiment for `docs/projects/ruff-01-lossless-source` (`RLS-SPEC`). It answers one
question: which compiler-owned data reconstructs an accepted Lean source file exactly, and which
data only appears to.

Nothing here imports `LeanFmt`. The oracle must be able to contradict the product.

```sh
./run.sh            # 13 cases, expects 0 failures
```

Findings are frozen in `docs/projects/ruff-01-lossless-source/notes/01-source-authority.md`; the
transcript is `docs/projects/ruff-01-lossless-source/evidence/01-round-trip.txt`.

## Parts

- `RoundTrip.lean` — parse-level oracle. Reconstructs each file two independent ways (raw source
  slices, and the parser's own atom/ident payloads) and compares against both the on-disk bytes and
  `raw.crlfToLf`. One file per process: `importModules (loadExts := true)` replays `[init]` code and
  cannot run twice in one process against different module sets.
- `ProbePlugin.lean` — the same reconstruction from inside a module linter, where the token table
  contains the file's own `syntax` declarations. This is the only position that can parse
  `fixtures/Syntax.lean`.
- `fixtures/` — tracked adversarial modules: trivia forms, token payloads whose source text might
  differ from the parsed atom, and file-local parser extensions.
- `run.sh` — generates the byte-exotic fixtures (CRLF, BOM, tabs, isolated `\r`, absent final
  newline, `#exit`) and asserts a declared outcome per fixture.

Byte-exotic fixtures are generated rather than tracked because `tests/boundary/run.sh` requires
every tracked `.lean` file to begin with `module`, which a CRLF or BOM fixture cannot.

## Exit codes

`run.sh` classifies each fixture by the oracle's exit code, so a change in Lean's parser contract
fails loudly instead of quietly reclassifying itself.

| code | meaning | expected for |
| --- | --- | --- |
| 0 | parsed; trivia reconstructs the parsed string byte-for-byte | ordinary accepted files |
| 1 | parsed, but reconstruction diverged | `#exit` only |
| 3 | the parser rejected the file | tabs, BOM, isolated `\r` |
