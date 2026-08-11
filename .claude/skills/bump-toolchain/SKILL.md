---
name: bump-toolchain
description: Move lean-fmt's pinned Lean toolchain to a new release. Use when bumping the Lean version, upgrading lean-toolchain, reacting to a red next-toolchain CI probe, or adapting to upstream formatter/Lake changes after a Lean release.
---

# Bump the pinned Lean toolchain

The procedure and the failure modes are documented in [`docs/toolchain-upgrade.md`](../../../docs/toolchain-upgrade.md);
read it first. lean-fmt depends on Lean internals that are private or de-facto-stable — the snapshot walk in
`LeanFmt/Analysis.lean`, the registered formatter documents, `parserOfStack`'s stack shape, and three non-`public` Lake
declarations reached through `import all Lake.Build.Run` — so a bump is an event to test, not a version-string edit.

CI's weekly `next-toolchain` job (`.github/workflows/ci.yml`) has usually already told you what the release moves:
vendored-region drift, whether it builds, and how many files `format --check` would rewrite. Read that run's summary
before starting.

## Steps

1. `elan toolchain install leanprover/lean4:vX.Y.Z` (skip if installed), then move `lean-toolchain` to
   `leanprover/lean4:vX.Y.Z`.
2. `lake build` and `lake exe lean-fmt-tests`. Compile errors here are the cheap half of the audit — a rename breaks
   the build, which is the good case. A *behaviour* change does not; two load-bearing ones are listed in
   `docs/toolchain-upgrade.md` (`monitorBuild`, `finalizeBuild`).
3. `lake lint` — the formatter over its own sources. Canonical-byte drift shows here first.
4. Run the suites that pin upstream behaviour and read every failure as a claim about an upstream change *before*
   repairing anything:

   ```sh
   lake test -- --suites native-layout style lossless module-formatter compiler downstream lsp lsp-acceptance editor
   ```

   What each suite pins, and what a failure means, is in its module docstring and in step 3 of the doc's checklist.
5. Move the manual with you: set `docs/manual/lean-toolchain` to the same value, set its `verso` rev to the new Lean
   version (Verso's tags follow Lean releases one for one), then `lake update verso` and `lake exe docs` in
   `docs/manual`. The Pages workflow fails when the toolchains disagree; the root bump is not done while they do.
6. `lake test -- --all` plus `git diff --check`.
7. If canonical bytes legitimately changed, re-freeze the mathlib sample under the new toolchain and name, in the
   commit message, which upstream change moved which bytes. A bump that changes bytes without a named upstream cause
   is an undiagnosed defect with a green suite — do not ship it.
8. Cache and artifact compatibility need no migration: cache identity includes the toolchain, so the bump orphans
   every entry wholesale by design, and the first run after pays full cost. Say so if anyone asks.

Do not silence suites by "repairing" fixtures to match new output until you have decided the upstream change is
legitimate (step 4). Do not commit the probe's runner-side `lean-toolchain` rewrite — that job adapts nothing; the
adaptation is this checklist, on an ordinary PR.
