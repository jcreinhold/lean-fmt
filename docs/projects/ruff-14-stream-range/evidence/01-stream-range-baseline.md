# RSF-SPEC baseline: the stdin and range surface as it stands

Machine: darwin 25.5.0, arm64. Toolchain: the repository's `lean-toolchain`. Commit: the parent of the
`RSF-SPEC` commit. Build: `LEAN_NUM_THREADS=1 lake build` → `Build completed successfully (44 jobs)`.

## 1. No stdin surface, no range surface

```sh
run() { out=$(lake exe lean-fmt "$@" 2>&1 >/dev/null); code=$?; \
        printf '$ lean-fmt %s\nstderr(first line)=%s\nexit=%s\n\n' "$*" "$(printf '%s' "$out" | head -1)" "$code"; }
run format -
run format --stdin-filename X.lean
run format --range 0:10
run check -
```

```
$ lean-fmt format -
stderr(first line)=unknown option: -
exit=2

$ lean-fmt format --stdin-filename X.lean
stderr(first line)=unknown option: --stdin-filename
exit=2

$ lean-fmt format --range 0:10
stderr(first line)=unknown option: --range
exit=2

$ lean-fmt check -
stderr(first line)=unknown option: -
exit=2
```

All four are rejected by `parseFileArgs`'s catch-all (`Cli.lean:129-131`): any argument starting with
`-` that is not a known option is an error. Nothing downstream has ever seen a stdin target.

## 2. The source map is never populated in production

```sh
grep -n '\.mark\|Doc\.mark' LeanFmt/Printer.lean     # no output
grep -rn '\.mark' LeanFmt/ LeanFmtTest.lean
```

```
LeanFmt/Doc.lean:115:  | .nest _ d | .group d | .mark _ d => wellFormed d
LeanFmt/Doc.lean:121:  | .nest _ d | .group d | .mark _ d => 1 + size d
LeanFmt/Doc.lean:180:        | .mark _ d => fits remaining (.doc i m d :: z)
LeanFmt/Doc.lean:210:    | .mark r d => go w (.doc i m d :: .closeMark r outBytes :: z) col outBytes out marks
LeanFmtTest.lean:1607: … (unit tests only, five sites)
```

Every site is either `Doc`'s own definition or a unit test. `Printer.format` calls `renderText`
(`Printer.lean:2151`), the accessor that discards the map. The facility RSF-IMPL is told to reuse is
sound and unpopulated — recorded as an interface obligation in `notes/01-stream-range.md` §8.

## 3. Reflow stability is a property of `fits`, not of commands

Probe: `evidence/01-unit-independence-probe.lean`, run with
`lake env lean --run docs/projects/ruff-14-stream-range/evidence/01-unit-independence-probe.lean`.

It renders one "unit" — `group("aaaa" line "bbbb")` followed by trailing trivia — alone, then with a
1-character tail and a 16-character tail appended, at margin 10, and asks whether the unit's own bytes
survived.

```
margin 10
  newline-terminated trivia: solo="aaaa bbbb\n"
  short-tail prefix stable = true
  long-tail  prefix stable = true
  with short tail = "aaaa bbbb\nx"
  with long  tail = "aaaa bbbb\nyyyyyyyyyyyyyyyy"
  same-line trivia (space)  : solo="aaaa bbbb "
  short-tail prefix stable = false
  long-tail  prefix stable = false
  with short tail = "aaaa\nbbbb x"
  with long  tail = "aaaa\nbbbb yyyyyyyyyyyyyyyy"
```

Mechanism: `fits` walks the tail of the work list and stops only at something it treats as a line
break. A `verbatim` holding a newline is such a thing (`Doc.lean:174-176`); a space is not. So a unit
ending in newline-bearing trivia is immune to everything after it, and a unit that is not so terminated
can be rebroken by a **one-character** tail.

This is the boundary condition `notes/01-stream-range.md` §4 freezes, and it is pinned by a
characterization test in `LeanFmtTest.lean`'s layout suite so it cannot drift silently.

## 4. Comment ownership, from the `RLC-SPEC` measurement

Not re-measured here; cited from `ruff-02-layout-core/results/01-design.md:55-69`:

```
leaves=56 nonempty_leading=0 trailing_spans_newline=11
comment_in_trailing=6
verdict=trailing-greedy
```

`nonempty_leading=0` over the sampled leaves: Lean puts everything between two tokens in the
*preceding* token's trailing run, including a stack of comments written above the next declaration.
`Tree.commands` builds extents from that split, so trivia between two commands belongs to the earlier
command — the ownership rule frozen in `notes/01-stream-range.md` §4.3.

## 5. Checks

```
LEAN_NUM_THREADS=1 lake build        Build completed successfully (44 jobs)
lake exe lean-fmt-tests              lean-fmt module-artifact tests passed
tests/boundary/run.sh                lean-fmt native module and dependency boundary passed
git diff --check                     (no output)
check_stack.py --structural          OK: 3 prompt(s), 0 warning(s), no errors.
write_next.py --check                OK: state/next.md matches first_unresolved=…
```
