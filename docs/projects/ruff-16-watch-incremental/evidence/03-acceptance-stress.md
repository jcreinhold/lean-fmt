# RWI-FINAL — event storms, repository states, and resource retention

Environment: `leanprover/lean4:v4.33.0-rc1`, Darwin arm64 (Darwin 25.5.0), APFS,
`git version 2.50.1 (Apple Git-155)`, commit `4c3c243` plus the `isCandidate` fix this prompt made.

Two fixtures, both built in the session scratchpad and both reproducible from the commands below:

* **`/tmp/wfix`** — a two-module Lake package, no git. Used for watch-loop dynamics, because a
  generation there is ~1 s and the signal is not swamped by this repository's own analysis cost.
* **`/tmp/acc/proj`** — a three-module Lake package inside a git repository. Used for repository
  states. The library is named `Proj`, not `Acc`: `lean_lib «Acc»` fails to elaborate because `Acc`
  resolves to Lean's well-founded-recursion accessibility relation.

Full-mathlib runs are forbidden by this stack's roadmap and none was made.

## 1. Watch-loop dynamics (`/tmp/wfix`)

```sh
app=/Users/jcreinhold/Code/lean-fmt/.lake/build/bin/lean-fmt
"$app" check --root .                        # warm the result cache first
"$app" check --watch --root . >out 2>err &
```

| Case | Stimulus | Result |
| --- | --- | --- |
| startup | — | 1 generation, 1 report |
| single edits | append to `Wfix/A.lean`, ×3, 4 s apart | 3 generations, 3 reports — exactly one each |
| **event storm** | **10 appends to `Wfix/B.lean` with no delay** | **banners 4 → 5: one generation** |
| shutdown | `SIGTERM` | exit 143, no torn output |

The storm line is the coalescing contract of §5 holding: ten observations collapse into one differing
snapshot and produce one generation.

## 2. Invalidation triggers (`/tmp/wfix`)

Each row is a single stimulus with a 5 s settle, measured as the change in the generation-banner
count.

| Stimulus | Generation fired |
| --- | --- |
| `printf '[lint]\n' > .lean-fmt.toml` (**create** a config) | yes |
| `touch lean-toolchain` | yes |
| create `Wfix/C.lean` | yes |
| delete `Wfix/C.lean` | yes |
| `printf 'x' > notes.txt` (unrelated non-source) | **no** |

The first row is what §6's ancestor-directory observation exists for: creating a config changes no
existing file's stamp, so it is only detectable by observing the recognized filenames in every
ancestor directory of every selected source. The last row is the negative control — the observer is
not merely firing on any filesystem activity.

## 3. Analysis failure and recovery (`/tmp/acc/proj`)

```sh
printf 'module\n\ndef broken := \n' > Proj/Broken.lean   # syntactically incomplete
```

| Point | Report | Session |
| --- | --- | --- |
| before | `files=6 … broken=0` | alive |
| after introducing the broken file | `files=6 … broken=1` | **alive** |
| after repairing it | `files=6 … broken=0` | alive |

A file that cannot be analyzed is reported as `broken` in that generation and does not end the
session — the roadmap's failure-recovery requirement. The session then recovers on the next
generation without intervention.

## 4. Repository states (`/tmp/acc/proj`)

### Index versus worktree

With `Proj/B.lean` staged and `Proj/C.lean` modified in the worktree only:

```
--staged   → index vs HEAD      → 1 changed path
--changed  → worktree vs HEAD   → 2 changed paths
```

### Branch comparison, three-dot

`feature` modified two files; `main` independently added `Proj/M.lean`.

```
lean-fmt: changed-file selection: main...HEAD (merge base)
lean-fmt: resolved base: 63e6f37178ede56d3b8299aab2b142dfef87a34c
lean-fmt: 2 changed path(s) selected; this run covers that subset, not the whole project
```

`Proj/M.lean` is correctly absent: three-dot asks what the branch changed, not how the trees differ.

### Rename and delete

```sh
git mv Proj/A.lean Proj/Renamed.lean
git rm -q Proj/C.lean
```

```
lean-fmt: changed-file selection: worktree vs HEAD
lean-fmt: not selected: Proj/C.lean: deleted
lean-fmt: not selected: Proj/A.lean: deleted
lean-fmt: 1 changed path(s) selected; this run covers that subset, not the whole project
mode=check files=1 …
```

The rename's **new** path is selected, its old path and the deleted path are both disclosed rather
than silently dropped, and `files=1` confirms only the surviving path reached analysis.

## 5. The bug this prompt found

Before the fix, on a repository containing an ordinary untracked `README.md` and an unignored `.lake`
tree:

```
lean-fmt: changed-file selection: worktree vs HEAD
lean-fmt: 4 changed path(s) selected; this run covers that subset, not the whole project
lean-fmt: selected file is not a Lean source: /private/tmp/acc/proj/.lake/config/0/lakefile.olean
```

The whole run aborted. §9.5 step 3 had assumed the ordinary gates would drop non-`.lean` and `.lake`
paths once they were handed to `execute` as the request's file list; they do not, because an
explicitly named file bypasses gates 2–4 and the floor it cannot skip is a hard error. Git names these
paths, the user does not, so the adapter now applies the floor itself. After the fix the same tree
gives:

```
lean-fmt: changed-file selection: worktree vs HEAD
lean-fmt: no changed Lean sources under .
```

Regression-tested in `tests/watch/run.sh`, and the test was mutation-checked: with the `isCandidate`
guard removed the suite fails with `an untracked non-Lean file aborted --changed`; restored, it passes.

## 6. Deterministic output

Five separate runs over an unchanged tree, `--output-format json --output-file`:

```
identical=yes
```

Across watch generations, with the document format replaced atomically each time:

| Generation | Tree | `files` | Against g1 |
| --- | --- | --- | --- |
| g1 | 5 sources | 5 | — |
| g2 | `Proj/Z.lean` added | 6 | **differ** |
| g3 | `Proj/Z.lean` removed again | 5 | **byte-identical** |

Returning the tree to an identical state produces byte-identical output three generations later. That
is the roadmap's "deterministic final output", and it simultaneously confirms §7's replacement
semantics for document formats — each generation wrote a complete document over the previous one.

## 7. Resource retention

Watch parent RSS, sampled after each of 13 generations driven by repeated edits (`/tmp/acc/proj`):

| Point | Parent RSS |
| --- | --- |
| after generation 1 | 51 328 KiB |
| after 13 generations | 51 344 KiB |
| min / max over the run | 51 328 / 51 344 KiB |
| **growth** | **16 KiB (0.03%)** |

Flat. This is the direct consequence of the re-exec design: the parent retains only the observed
snapshot, and each generation's analysis memory belongs to a child that exits. Nothing accumulates
across generations.

No run approached the stack's stop thresholds — 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new
swap. Peak aggregate figures were not separately instrumented because the parent is a poll loop at
~50 MiB and each child is one ordinary `execute`, whose envelope `ruff-05`/`ruff-11` already govern
and which `--max-memory` still bounds.

## 8. Orphaned temporaries

After `SIGTERM` during an `--output-file` watch session:

```sh
find /tmp -maxdepth 1 -name "*.lean-fmt-tmp" | wc -l
0
```

None. §8's argument — that clean shutdown follows from temp-then-rename atomicity rather than from
signal handling — holds in practice. This is a negative observation across the sessions run here, not
a proof that no interleaving can orphan a temporary; a signal landing between `writeFile` and
`rename` would leave one, and nothing collects it.
