# Upgrading the pinned Lean toolchain

This checklist is for maintaining **this repository** across a `lean-toolchain` bump. A consuming project's side of the
same event is `docs/ci.md` §"Installing and upgrading".

lean-fmt is pinned to one toolchain and leans on Lean internals that are private or de-facto-stable rather than
versioned APIs. A bump is an event to test, not a version-string edit. Nothing here is public API: every name below is
an internal this product happens to depend on, and the checklist exists because Lean is free to move any of them.

## What a bump can move

1. **The exact frontend's snapshot walk.** `LeanFmt/Analysis.lean` reads the command stream through
   `Lean.Language.Lean.InitialSnapshot`/`CommandParsedSnapshot` and `waitForFinalCmdState`. A change in snapshot
   structure shows up as wrong command boundaries or dropped commands, and the projection-tiling checks in the lossless
   suite see it first.
2. **The registered formatter documents.** Canonical layout derives from the same `Std.Format` documents Lean's
   pretty-printer produces (`Lean.PrettyPrinter.formatCategory`/`formatCommand`; registry lookup in
   `LeanFmt/Formatter.lean`, adaptation in `LeanFmt/Formatter/NativeLayout.lean`). An upstream combinator change —
   `sepByIndent.formatter`, `declModifiers`, `pushToken`, a parser's `ppLine`/`ppDedent` placement — changes canonical
   bytes. That can be legitimate. Make the change deliberately, with fixtures, never to silence a suite.
3. **Stack-shape assumptions.** `parserOfStack`'s formatter reads a fixed number of stack slots, and `NativeLayout`
   works around that by name. A signature change in `Lean.PrettyPrinter.Formatter` breaks at compile time — the good
   case. Behavior changes in `pushToken`'s re-lexing or `Std.Format`'s `fill` measurement break silently at width
   boundaries; the native-layout suite's multi-width renders exist for exactly this.
4. **The artifact schema and cache identity.** Both are pre-release; no backward compatibility is promised with
   artifacts or cache entries written under an earlier toolchain. Cache identity includes the toolchain, so a bump
   orphans every entry wholesale by design, and the first run after a bump pays full cost.
5. **Lake's build internals.** `LeanFmt/Project.lean` runs Lake's own graph rather than shelling out to `lake`, and it
   reaches three non-`public` declarations through `import all Lake.Build.Run`: `mkJobQueue`, `mkBuildContext'`, and
   `Workspace.startBuild`. Everything else is Lake's public surface — `Workspace.runBuild`, `Lake.ensureJob`,
   `Job.mapResult`/`zipWith`/`collectArray`, `Lake.setupServerModule`, the `olean`, `transImports`, and `setup` facets,
   and `Lake.Artifact`/`artifactWithExt`/`Hash.ofString?` for the `leanFmtArtifact` sidecar. The `setup` facet is the
   build path — `recFetchSetup` over `presetup` — and a file read from disk takes it; a buffer or a rewritten candidate
   takes `setupServerModule`, because their imports are not the ones on disk. If a bump changes what `presetup` folds
   into `leanOptions`, or moves imports out of `ModulePreSetup`, the two paths stop agreeing for unchanged files and the
   modes suite sees it. `LeanFmt/Cache.lean` reads Lake's `.trace` files through Lake's own readers —
   `BuildMetadata.fromJson?`, `ModuleOutputDescrs.fromJson?`, and `ArtifactDescr` — plus one more non-`public` name,
   `BuildMetadata.schemaVersion`, reached through `import all Lake.Build.Common`. That last one is the schema pin, and
   it is ours to make because Lake's parse does not: `BuildMetadata` does not carry the version it parsed, so nothing
   below would notice a schema change on its own. A rename breaks the build, which is the good case; a *behaviour*
   change does not. Two behaviours are load-bearing and silent if they move: `monitorBuild` failing the whole batch on
   any one registered job's failure, which is why `Project.graph` awaits jobs itself and never calls it, and
   `finalizeBuild` turning a stale `noBuild` target into `IO.Process.exit`, which is why it is never called on the
   no-build pass. If a bump makes a whole selection report artifact or setup misses at once, suspect the first; if a run
   exits silently mid-check, suspect the second.

## Checklist

1. Move `lean-toolchain`, then `lake build` and `lake exe lean-fmt-tests`. Compile errors here are the cheap half of the
   audit.
2. `lake lint` — the formatter over its own sources. Drift in canonical bytes shows here first.
3. Run the fixtures that should fail loudly on upstream layout drift, and read every failure as a claim about an
   upstream change before repairing anything:
   - the native-layout suite — pins the upstream document shapes the adapter repairs or refuses (attribute lines,
     `sepByIndent` alignment, guarded `let` bail-outs, constructor docstrings, the `]do` separator).
   - the style suite — the golden candidate at widths 20/40/80/100.
   - the lossless suite — projection tiling and the `choice` gate.
   - the module-formatter suite — the `#exit` verbatim tail.
   - the compiler and downstream suites — the plugin, the facet, and artifact/exact route agreement. Lake's `plugins`
     field is experimental and its target-key syntax has changed more than once; re-check it on every bump.
   - the lsp suite, then lsp-acceptance and editor — protocol, cancellation latency, and the editor stanza in
     `docs/editor-setup.md`.
   Run them with `lake test -- --suites native-layout style lossless module-formatter compiler downstream lsp
   lsp-acceptance editor`.
4. Run everything — `lake test -- --all` — plus `git diff --check`.
5. If canonical bytes legitimately changed, the frozen mathlib evidence no longer describes this toolchain: re-freeze a
   sample under the new one, and say in the commit message which upstream change moved which bytes.

A bump that changes bytes without a named upstream cause is not done; it is an undiagnosed defect with a green suite.
