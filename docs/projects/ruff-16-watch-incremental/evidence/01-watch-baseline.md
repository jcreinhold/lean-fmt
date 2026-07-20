# RWI-SPEC baseline — what the platform and the product actually do

Environment for every measurement below: commit `77a1b62`, `leanprover/lean4:v4.33.0-rc1`, Darwin
arm64 (Darwin 25.5.0), APFS, `git version 2.50.1 (Apple Git-155)`, repository
`/Users/jcreinhold/Code/lean-fmt` (110 selected sources). Probe sources are reproduced inline; they
were run from the session scratchpad, not committed to the tree.

## 1. Lean 4.33 exposes no filesystem-watch primitive

```sh
cd ~/.elan/toolchains/leanprover--lean4---v4.33.0-rc1/src/lean
grep -rni "inotify\|fsevent\|kqueue\|watchFile\|FileWatcher" Init/ Std/
ls Std/Async/ Std/Internal/UV/
grep -rni "fs_event\|fsEvent\|uv_fs_poll" Std/Internal/UV/ Std/Async/
```

The first and third greps return **no matches**. The directory listing is the reason this matters:

```
Std/Async/:        Basic ContextAsync DNS IO Process Select Signal System TCP Timer UDP
Std/Internal/UV/:  DNS Loop Signal System TCP Timer UDP
```

libuv itself provides `uv_fs_event` and `uv_fs_poll`. Lean's `Std.Internal.UV` binds Signal, Timer,
TCP, UDP, DNS and System — and **not** the two filesystem-watch handles. So the absence is a missing
binding, not a missing platform capability, and no amount of `Std.Async` reaches it. Watch mode
therefore observes by polling. `Std.Async` is used nowhere in the product tree today
(`grep -rn "Std.Async\|Std.Internal.UV" LeanFmt/ Main.lean` → no matches).

## 2. `mtime` carries populated nanoseconds; `(mtime, byteSize)` is a sufficient change signal

`IO.FS.Metadata` (`Init/System/IO.lean:1115`) exposes `modified : SystemTime` with
`sec : Int` and `nsec : UInt32`, plus `byteSize : UInt64`. Whether the binding *populates* `nsec` or
truncates to whole seconds decides whether polling can see a fast edit at all. Measured:

```lean
def main : IO Unit := do
  let p : System.FilePath := "probe-target.txt"
  let mut stamps : Array (Int × UInt32 × UInt64) := #[]
  for i in [0:12] do
    IO.FS.writeFile p (String.ofList (List.replicate (i+1) 'x'))
    let m ← p.metadata
    stamps := stamps.push (m.modified.sec, m.modified.nsec, m.byteSize)
  ...
  IO.FS.writeFile p "AAAA"; let a ← p.metadata
  IO.FS.writeFile p "BBBB"; let b ← p.metadata
```

```
sec=1784560170 nsec=888636590 size=1
sec=1784560170 nsec=888732216 size=2
sec=1784560170 nsec=888854175 size=3
sec=1784560170 nsec=888923676 size=4
sec=1784560170 nsec=888978884 size=5
sec=1784560170 nsec=889032552 size=6
sec=1784560170 nsec=889093718 size=7
sec=1784560170 nsec=889144094 size=8
sec=1784560170 nsec=889229928 size=9
sec=1784560170 nsec=889317804 size=10
sec=1784560170 nsec=889373721 size=11
sec=1784560170 nsec=889420596 size=12
nonzero-nsec=12/12
same-size a=(1784560170,889763307) b=(1784560170,889850807) distinct=true
```

Twelve consecutive writes landed inside **one** wall-clock second and every one carried a distinct
`nsec`, roughly 50–120 µs apart. The final line is the case a size-only signal misses: a rewrite of
identical length is still distinguishable by `nsec`.

Scope of the claim: this is Darwin/APFS. Nanosecond `mtime` is not universal — a coarse-granularity
filesystem can return equal stamps for a same-second, same-size edit. §2 of the freeze specifies the
consequence, which is bounded detection *latency* and never a wrong result, because every emitted
generation re-reads and re-digests source.

## 3. Fixed per-run cost dominates; file count barely matters warm

```sh
app=.lake/build/bin/lean-fmt
/usr/bin/time -p "$app" check --root . LeanFmt/Comments.lean     # single file
/usr/bin/time -p "$app" check --root .                            # complete project
LEAN_FMT_PROFILE_PHASES=1 "$app" check --root . 2>&1 | grep '^phase\.'
```

| Workload | Cache state | Wall time |
| --- | --- | --- |
| 1 file (`LeanFmt/Comments.lean`) | cold process, warm result cache | 0.85 s |
| 1 file, repeated | warm | 0.46 s, 0.44 s |
| 110 files (complete project) | **cold result cache** | 64.98 s |
| 110 files (complete project) | warm result cache | 0.59 s |

Phase profile, warm:

| Phase | 1 file | 110 files |
| --- | --- | --- |
| `discovery` | 33 ms | 34 ms |
| `workspace_load` | 344 ms | 301 ms |
| `selection_snapshot` | 0 ms | 5 ms |
| `import_findings` | 0 ms | 26 ms |
| `cache_epoch` | 61 ms | 61 ms |
| `cache_lookup` | 1 ms | 37 ms |

Read this table as the central quantitative result of the prompt. `workspace_load`, `discovery` and
`cache_epoch` together are ~400 ms and are **independent of how many files were selected** — they are
paid once per process. Going from one file to the complete 110-file project adds ~70 ms warm
(`selection_snapshot` + `import_findings` + `cache_lookup`, 1 ms → 68 ms). The complete-project warm
run is 0.59 s against the single-file 0.44 s.

The cold-cache figure (64.98 s, a 110× ratio against warm) is recorded to identify which workload the
0.59 s belongs to: it is the *cache-warm* workload of `CLAUDE.md`'s four, which is the steady state a
watch loop runs in after its first generation. A watch session's first generation pays the cold price
once.

No memory figure is recorded: this prompt ships no production code and runs no resource experiment.
`RWI-FINAL` owns retention and RSS measurement.

## 4. `IO.Process.output` does not throw on a missing binary

```lean
try
  let out ← IO.Process.output { cmd := "definitely-not-git", args := #["--version"] }
  IO.println s!"no throw: exit={out.exitCode}"
catch e => IO.println s!"threw: {e}"
```

```
no throw: exit=255
```

The natural implementation of "Git absence is a clear request error" — wrapping the spawn in `try` —
therefore **does not fire**. Absence must be detected from the exit code.

## 5. Probing for a repository: `rev-parse`, not `diff`

```sh
cd /tmp/norepo   # an empty non-repository directory
git rev-parse --show-toplevel ; echo "exit=$?"
git diff --name-status HEAD  ; echo "exit=$?"
```

```
fatal: not a git repository (or any of the parent directories): .git
exit=128
```

against `git diff --name-status HEAD`, which exits **129** after printing its entire ~90-line option
usage to stderr. Confirmed from Lean through the production spawn path:

```
rev-parse outside repo: exit=128 stderr=fatal: not a git repository (or any of the parent directories): .git
```

One clean line at a stable exit code versus a usage dump. The adapter probes with `rev-parse`.

## 6. Only `-z` yields byte-exact paths

Fixture: a repository containing `Ünïcode Spaced.lean` and `quo"te.lean`.

```sh
git diff --name-status HEAD~1
git diff --name-status -z HEAD~1 | tr '\0' '@'
git -c core.quotePath=false diff --name-status HEAD~1
```

Default:

```
A	"quo\"te.lean"
A	"\303\234n\303\257code Spaced.lean"
```

`core.quotePath=false`:

```
A	"quo\"te.lean"
A	Ünïcode Spaced.lean
```

`-z` (NUL rendered as `@`):

```
A@.gitignore@D@C.lean@A@New.lean@R100@A.lean@Renamed.lean@A@quo"te.lean@M@sub/B.lean@A@Ünïcode Spaced.lean@
```

Default output C-quotes non-ASCII into octal escapes. `core.quotePath=false` fixes the non-ASCII case
and **still quotes the embedded double quote** — so it is not a sufficient remedy. Only `-z` is
byte-exact for both. The `-z` stream also shows the field-count asymmetry the parser must honor: a
rename is three NUL-terminated fields (`R100`, old, new); every other status is two.

## 7. Change-class fixture

Repository with a rename, a delete, a modification, an untracked file and an ignored file:

```
== git status --porcelain=v1
D  C.lean
R  A.lean -> Renamed.lean
 M sub/B.lean
?? .gitignore
?? New.lean

== git diff --name-status HEAD          (worktree vs HEAD)
D	C.lean
R100	A.lean	Renamed.lean
M	sub/B.lean

== git diff --cached --name-status HEAD (index vs HEAD)
D	C.lean
R100	A.lean	Renamed.lean

== git ls-files --others --exclude-standard
.gitignore
New.lean
```

Two facts drive the freeze. `git diff` **never reports untracked files** — `New.lean` appears only in
`ls-files --others`, so a selection built from `diff` alone silently skips every newly created file.
And `--exclude-standard` correctly withholds `Ignored.lean` once `.gitignore` names it. Rename
detection was on by default here: plain `git diff --name-status HEAD` already produced `R100`,
identical to the explicit `--find-renames` run.

## 8. Two-dot versus three-dot

Fixture: `main` and `feature` diverge from a common base; `feature` adds `Feat.lean` and
`Ignored.lean`, `main` independently adds `MainOnly.lean`.

```
== git diff --name-status main..feature
D	.gitignore
R100	Renamed.lean	A.lean
A	C.lean
A	Feat.lean
A	Ignored.lean
D	MainOnly.lean
D	New.lean
D	"quo\"te.lean"
M	sub/B.lean
D	"\303\234n\303\257code Spaced.lean"

== git diff --name-status main...feature
A	Feat.lean
A	Ignored.lean

== git merge-base main feature
eefdc2ec
```

Two-dot reports ten paths, most of them artifacts of what `main` did independently — `MainOnly.lean`
appears as a deletion the branch never performed. Three-dot reports exactly the two files the branch
touched. "What did my branch change" is the merge-base question, so `--changed BASE` uses three-dot.
