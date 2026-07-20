# RCI-SPEC raw evidence

Machine: Darwin 25.5.0, arm64. Toolchain: `leanprover/lean4:v4.33.0-rc1` (Lean 4.33.0, commit
`62eed1db4d67327ec8120be05f1a1b0847d74561`). Repository commit: `60e5da5`, working tree clean apart
from this prompt's own changes. Project: this repository, 112 selected sources.

Binary: `.lake/build/bin/lean-fmt`, built by `LEAN_NUM_THREADS=1 lake build`.

## 1. Whole-project invalidation, at entry granularity

Counts come from the profile channel added by this prompt (`LEAN_FMT_PROFILE_PHASES=1`, stderr,
`cache.targets` / `cache.index_hits` / `cache.served`). Wall time is `/usr/bin/time -p`, `real`.

```sh
rm -rf .lean-fmt-cache
LEAN_FMT_PROFILE_PHASES=1 .lake/build/bin/lean-fmt check --root .      # cold
LEAN_FMT_PROFILE_PHASES=1 .lake/build/bin/lean-fmt check --root .      # unchanged
echo '-- comment' >> experiments/layout-core/LayoutProbe.lean
LEAN_FMT_PROFILE_PHASES=1 .lake/build/bin/lean-fmt check --root .      # one-file edit
# restore the file
LEAN_FMT_PROFILE_PHASES=1 .lake/build/bin/lean-fmt check --root .      # after revert
```

| Run | `targets` | `index_hits` | `served` | wall | index files in `.lean-fmt-cache/results/` |
| --- | --- | --- | --- | --- | --- |
| cold | 112 | 0 | 0 | 61.32 s | 1 (`e0551306…`) |
| unchanged re-run | 112 | **112** | **112** | 0.58 s | 1 (same file) |
| after appending one comment to one file | 112 | **0** | **0** | 59.10 s | **2** (`60de4f63…` added) |
| after reverting that comment | 112 | **112** | **112** | 0.70 s | 2 (the original file served again) |

The decisive number is `index_hits = 0`, not `111`. The edit did not invalidate the edited file's
entry; it invalidated the **name of the index**, so no entry was reachable. Wall time alone cannot
show this — it is exactly the ambiguity that let `ruff-16` read the same figure as an in-process
reuse defect.

The revert row is a second independent confirmation: because the index name is a content digest over
the whole project source set, restoring the bytes restores the *old file name* and the original index
is served again, unchanged. Both index files remain on disk; nothing collects the orphan.

Mechanism, read from the source at this commit: `Cache.sourceRootParts?` (`Cache.lean:147-161`) walks
`workspace.augmentedLeanSrcPath` for non-`.lake` `.lean` files and digests each one's bytes;
`environmentDigest?` folds those parts into `environment` (`Cache.lean:190-197`); `baseDigest` folds
`environment` (`Cache.lean:219`); `indexPath` is `results/{baseDigest}.json` (`Cache.lean:226`).

## 2. No in-process retention exists

`Application.execute` opens the cache inside the function body, per call
(`Application.lean:1298`), and `open?` allocates `loadedEntries ← IO.mkRef none` on every
construction (`Cache.lean:267`). There is no value that outlives a call to `execute` and no
process-scoped cache state. The `ruff-16` diagnosis has no mechanism.

## 3. What Lake's module traces actually record

Sampled from `.lake/build/lib/lean/LeanFmt/*.trace`, schema `2025-09-10`.

Per module `M`, `inputs` contains:

- `["deps", [… ["imports", <imports>] …]]`. `<imports>` is an **array of pairs when `M` has
  in-workspace imports and the scalar nil hash `"00000000000006bb"` when it has none**
  (`LeanFmt.Digest` is the observed nil case in this repository). A consumer must tolerate both
  shapes; `Cache.lean`'s existing `OleanTrace` parses neither, since it reads only `schemaVersion`
  and `outputs`.
- For each **direct in-workspace import `X`**, two entries:
  `["X transitive imports (all)", h]` and `["X:importAllArts", h]`.
- Toolchain imports (`Lake.Build.Module`, `Lean.Util.Diff`, …) are **absent** from `deps.imports`
  entirely. They are covered by the separate `["Lean 4.33.0, commit …", h]` input.
- `[<absolute source path of M>, h]` — `M`'s own source hash. The key is an absolute path, not a
  path relative to the workspace root.
- `["Module.name: M", h]`, `["options", h]`, `["isModule: …", h]`, `["Package.id?: …", h]`,
  `["Module.leanArgs: …", h]`.

And, outside `inputs`, `outputs` (content-addressed artifact names, leading 16 hex digits are the
content hash) and a combined `depHash`.

### 3.1 The refutation: `"X transitive imports (all)"` excludes `X` itself

Experiment. `LeanFmt.ArtifactModel` is imported directly by `LeanFmt.Edit` and `LeanFmt.Imports`;
`LeanFmt.Application` imports both transitively.

**Edit 1 — append a comment to `ArtifactModel.lean`, `lake build`.** Only `ArtifactModel` rebuilt.
Trace diff:

| Module | changed inputs |
| --- | --- |
| `ArtifactModel` | own-source hash `7ab2646a7078ab61 → 420cd412e8533c08`; `depHash` |
| `Edit` | *nothing* |
| `Imports` | *nothing* |
| `Application` | *nothing* |

**Edit 2 — add `def rci16bProbe : Nat := 42` to `ArtifactModel.lean`, `lake build`.** The whole
downstream tree rebuilt. Trace diff:

| Module | changed inputs |
| --- | --- |
| `ArtifactModel` | own-source hash `7ab2646a7078ab61 → ca3f825f094fec27`; `depHash` |
| `Edit` | **`ArtifactModel:importAllArts` `24ff2f6c3dd2f726 → 3c33016ab510a8b4`**; `depHash` |
| `Imports` | **`ArtifactModel:importAllArts` `24ff2f6c3dd2f726 → 3c33016ab510a8b4`**; `depHash` |
| `Application` | `Cache`/`Config`/`Edit`/`Imports`/`Printer`/`Project`/`Semantic`/`Suppression` **`transitive imports (all)`**; `depHash` |

Note what did **not** change in edit 2: `Edit`'s recorded
`["LeanFmt.ArtifactModel transitive imports (all)", …]`. Editing `A` so that `A`'s `.olean` changed
left every dependent's `"A transitive imports (all)"` entry untouched.

`"X transitive imports (all)"` therefore hashes the closure of **`X`'s imports**, excluding `X`. This
refutes the reading in `roadmap.md` and in `notes/01-what-is-provable.md` §6, both of which proposed
comparing `B`'s recorded `["A transitive imports (all)", h]` against `A`'s current value. That key
does not carry `A`'s own content, so the comparison would have passed on exactly the grammar change
the stack exists to catch. The key that does carry it is the sibling `["A:importAllArts", h]`.

Corroboration inside edit 2: `Edit` and `Imports` have identical import sets (`ArtifactModel` only)
and identical `"…transitive imports (all)"` values before and after (`3f85680d25634877`, then
`78e0bff93a668918` as seen from `Application`) — consistent with the key being a function of the
import closure and not of the module.

Also note edit 1: a comment-only change leaves every dependent's expectation untouched, because
Lake's downstream keys are over **artifact content**, not source bytes. That is the correct answer,
not a gap: a comment cannot change how a dependent's bytes parse.

### 3.2 `importAllArts` is exactly recomputable from the importee's own trace

`Lake/Build/Module.lean` `computeExportInfo` (v4.33.0-rc1, lines 463-509):

```lean
let allArtsTrace := BuildTrace.nil s!"{mod.name}:importAllArts"
…
allArtsTrace := allArtsTrace.mix
  olean.trace |>.mix oleanServer.trace |>.mix oleanPrivate.trace |>.mix irSig.trace |>.mix ir.trace
```

with (`Lake/Build/Trace.lean`) `BuildTrace.nil caption = {caption, hash := Hash.nil, mtime := 0}` —
the caption does **not** enter the hash — `Hash.nil = ⟨1723⟩`, and `Hash.mix = mixHash` on the
underlying `UInt64`. The legacy (non-module-system) branch mixes `olean` alone. Each mixed value is
the content hash Lake also writes as the leading 16 hex digits of the corresponding `outputs` entry.

Numeric confirmation. `LeanFmt.ArtifactModel` after edit 2 had
`outputs = {o: [f659a39be8d485d9.olean, 6be948864a1044cb.olean.server, 14a93913156b7410.olean.private],
rs: d8e841117871da2f.ir.sig, r: c4454e3bee79ad16.ir}`. Folding those five in that order from
`Hash.nil`:

```
$ lake env lean --run MixProbe.lean
3c33016ab510a8b4
expected (recorded in Edit.trace): 3c33016ab510a8b4
```

Exact match. A dependent's recorded expectation for `A` is recomputable from `A`'s own trace file
alone — no import resolution, no closure walk, no second execution engine.

This identity is pinned by `testLakeTraceCharacterization` in `LeanFmtTest.lean`, which recomputes it
for **every** (importer, importee) pair present in the built tree. Mutation-checked: reversing the
mix order makes it fail (`LeanFmt.LosslessSource records 1c74061028900f9a for LeanFmt.Digest,
recomputed 451d87f14c79885a`).
