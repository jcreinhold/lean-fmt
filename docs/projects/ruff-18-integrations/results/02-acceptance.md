# RDI-FINAL — the recipes and the installation path, from clean sources

Claim: **RDI-FINAL**. Prompt `02-acceptance`. Status: verified.

## What shipped

- `tests/ci/run.sh` — new suite, 16 checks, ~91 s. It builds a consuming project that takes lean-fmt
  as a **git** dependency with real commit history, runs all four published recipes against it,
  asserts the cache instruction in both directions, and builds a `git archive` from clean.
- `docs/ci.md` — two corrections (below) and a pointer to the suite that now gates it.
- `CLAUDE.md`, `README.md` — the suite registered, with its cost and its committed-state-only caveat.

## Why a new suite rather than extending `tests/downstream/run.sh`

The prompt asked for the existing harness to be extended "unless the shapes genuinely differ." They
differ on all three axes this prompt cares about. `downstream` uses a **committed fixture** with a
**path** `require` and **no git history**; these recipes need a **generated** consumer with a **git**
`require` and a **merge base**, because `--changed-since` has nothing to resolve without one and the
cache check needs a dependency binary under `.lake/packages`. Folding that into `downstream` would
have meant a second workspace inside a suite whose whole subject is one workspace.

## The clean-source claim, taken literally

Prompt 02's framing was that this working tree proves nothing: it has a warm `.lake`, a warm
`.lean-fmt-cache`, a resolved manifest, and its own `lean-fmt.toml`. All four are removed here.

| Property of this tree | How the suite removes it |
| --- | --- |
| warm `.lake` | consumer built in `mktemp -d`; archive extracted to a second temp dir |
| warm `.lean-fmt-cache` | `rm -rf` before the cold measurement; the archive never had one |
| resolved manifest | consumer runs `lake update` from no manifest at all |
| this repo's `lean-fmt.toml` | the consumer has none, so discovery finds nothing and defaults apply |

The archive assertions check the first two directly — `[ ! -e "$archive/.lake" ]` and
`[ ! -e "$archive/.lean-fmt-cache" ]` — so the test fails rather than silently passing if a future
`.gitattributes` or `.gitignore` change starts shipping build state.

## Results

All 16 checks pass. Full transcript:

```
--- Recipe 1: the minimal lake lint job ---
  ok   lake check-lint reports a configured driver
  ok   lake lint exits 0 on a clean tree
  ok   lake lint exits 1 and reports findings through the driver
--- Recipe 2: SARIF into code scanning ---
  ok   a run with findings writes a SARIF log and exits 1
  ok   a clean run writes a schema-shaped SARIF log with zero results
  ok   an exit-2 run writes no SARIF file, which is why the recipe guards on its existence
  ok   the consuming project SARIF log validates against the vendored 2.1.0 schema
--- Recipe 3: changed files on a pull request ---
  ok   --changed-since selects the branch subset and announces its base
  ok   --changed-since selecting nothing exits 0 with a notice and analyzes nothing
--- Recipe 4: a generic runner, exit codes only ---
  ok   the generic recipe distinguishes findings (1) from infrastructure failure (2)
  ok   a broken pipe keeps the run exit code
--- Cache: what docs/ci.md tells CI to cache ---
  ok   an mtime-preserving restore of .lake and .lean-fmt-cache hits the cache
  ok   a rebuilt formatter binary orphans the index, as docs/ci.md warns
--- Installation from clean sources ---
  ok   the archive carries the files a build needs and none of the build outputs
  ok   a clean git archive builds with no working-tree state
  ok   the binary built from the archive runs clean against the archive
ci recipes ok
tests/ci/run.sh  98.61s user 42.44s system 154% cpu 1:31.10 total     exit 0
```

### The cache check is the one that earns its keep

`docs/ci.md` tells a job to cache `.lake` and `.lean-fmt-cache` under one key. That instruction is
only correct because cache identity takes the formatter binary's `(path, size, mtime)`. The suite
asserts both directions, because either alone is satisfiable by a broken implementation:

```
$ tar -czf cache.tgz .lake .lean-fmt-cache && rm -rf .lake .lean-fmt-cache && tar -xzf cache.tgz
$ lake exe lean-fmt check --root .
index before: .lean-fmt-cache/results/80665081…7f4b.json
index after:  .lean-fmt-cache/results/80665081…7f4b.json     unchanged → hit

$ touch .lake/packages/lean-fmt/.lake/build/bin/lean-fmt
$ lake exe lean-fmt check --root .
index now:    a second file beside the first                 changed → miss, as documented
```

A total cache miss is indistinguishable from a warm cache that is merely slow, so no existing suite
would have caught this document going wrong. That is precisely the "future change could silently
break" case the prompt asked for a gate on.

### The archive builds from committed state alone

```
$ git archive --format=tar HEAD | tar -x -C "$archive"
$ cd "$archive" && lake build
Build completed successfully (52 jobs).                       exit 0, 18.5 s wall (LEAN_NUM_THREADS=4)
$ ./.lake/build/bin/lean-fmt check --root .                   exit 0
```

Nothing was missing from the archive. The build needed no file the repository does not commit, and
the resulting binary reports its own tree clean.

## Corrections made to `docs/ci.md`

**`lake update`'s failure modes, now measured rather than caveated.** `01-recipes` recorded that
`lake update` accepts an unknown package name and exits 0, but could only observe it against a *path*
dependency and labeled it accordingly. Re-measured here in a git-dependency workspace:

```
$ lake update definitely-not-a-package                        exit 0   (silently does nothing)
$ lake update    # with the pin set to 000000…               exit 1
    fatal: unable to read tree (0000000000000000000000000000000000000000)
    error: external command 'git' exited with code 128
```

So the hazard is narrower and sharper than `01-recipes` could state: a bad **revision** fails loudly,
a mistyped **package name** does not. `docs/ci.md` now says exactly that, and the path-dependency
caveat is gone — the carried-over uncertainty is closed.

**A pointer to the gate.** `docs/ci.md` now names `tests/ci/run.sh` as the suite that fails when a
recipe stops working, so a reader can tell documentation from aspiration.

No recipe needed a functional fix. Every command in `docs/ci.md` behaved as `01-recipes` transcribed
it, which is the expected outcome given that prompt wrote them from transcripts rather than help text.

## Checks

| Check | Result |
| --- | --- |
| `LEAN_NUM_THREADS=1 lake build` | exit 0 |
| `LEAN_NUM_THREADS=1 lake exe lean-fmt-tests` | exit 0 |
| `lake lint` | exit 0, `files=34 findings=0` |
| every `tests/*/run.sh` | **21/21 pass, 0 fail** |
| `git diff --check` | clean, read in full |

Per-suite, in sweep order: boundary 3s, cache 42s, catalog 23s, check 23s, **ci 86s**, compiler 76s,
discovery 15s, downstream 6s, imports 11s, layout 49s, lossless 56s, lsp 19s, modes 80s, printer 89s,
reporting 23s, scale 4s, semantic 19s, stream 80s, suppression 10s, syntax 36s, watch 2s.

Two notes on reading that table.

`tests/watch/run.sh` passed because the index was clean at the time. `CLAUDE.md` records that its
§9.6 runs `check --staged` against *this* repository and fails whenever a `.lean` file is staged;
that is a known suite defect owned by `ruff-20-acceptance`, not a property of this change.

An intermediate `git diff --check` during the sweep reported trailing whitespace in
`tests/cache/project/Fixture/Leaf.lean`. That was the cache suite mutating its own fixture while
running, not a defect in this change; the check is clean once the sweep completes, and it is recorded
here so the transient reading is not mistaken later for a real one.

## Remaining uncertainty

- **No recipe has run on a GitHub runner, and this prompt could not close it.** Every *command*
  inside the workflow YAML is executed by `tests/ci/run.sh`; the YAML scaffolding around them — step
  ordering, `hashFiles`, `$GITHUB_OUTPUT`, `permissions`, `actions/cache` key syntax — is derived from
  `leanprover/lean-action`'s `action.yml` and GitHub's documented expression syntax, not observed
  running. Closing it needs a code-scanning upload, which is remote state this stack's stop rules
  forbid. **Recorded as a standing limitation, deliberately not narrowed away**: the recipes' commands
  are tested, their YAML is reviewed.
- **`actions/cache` mtime preservation is inferred one step.** The suite proves the *invariant* — an
  mtime-preserving tar round-trip hits, a touched binary misses — using `tar` directly. That
  `actions/cache` itself preserves mtimes follows from its using `tar`, and is not separately
  observed. If it ever stopped, the suite would still pass while CI silently lost its cache. A
  runner-side check is the only thing that would close this, and it is blocked by the same stop rule.
- **The suite tests committed state only.** `file://` clone at `HEAD` plus `git archive` both read
  committed state, so a green run says nothing about uncommitted work. This is correct scope for an
  installation test but is a real footgun; it is called out in the script's header comment, in
  `CLAUDE.md`, and here.
- **`--root` on a missing directory** still reports a raw IO error rather than the repository's
  `selected file does not exist: <arg>` shape. Carried forward from `01-recipes` unchanged: the exit
  code is 2 and the path is named, so no recipe is wrong, and `CLAUDE.md` scopes the message
  convention to new path-taking surface. Restated so it is not rediscovered as new.
