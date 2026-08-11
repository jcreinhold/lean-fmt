---
name: release-lean-fmt
description: Cut a lean-fmt release (version bump, CHANGELOG, tag) that publishes prebuilt binaries via CI. Use when releasing lean-fmt, bumping the version for a release, or cutting a vX.Y.Z tag.
---

# Release lean-fmt

**Publishing happens only in CI.** Pushing a `vX.Y.Z` tag fires `.github/workflows/release.yml`: a full `lake test`
gate plus a smoke test on four platform legs (oldest available Linux runners, so the glibc floor stays 2.35), then
tarball packaging and a `gh release` upload with a concatenated `SHA256SUMS` that `install.sh` greps. The same
workflow can be dispatched manually with an existing tag name to backfill binaries onto an old tag. NEVER build and
upload release tarballs locally — a tarball that skips the four-leg gate is not a release.

There is no crates.io here, so a botched tag is not permanent — but a tag that users and Lake dependencies already
pin is costly to move, and a release that fails midway ships partial assets. Treat the tag push as irreversible.

## Steps

Steps 1–4 are reversible. Step 5 (tag push) is not — **stop and get explicit human confirmation first.**

### 1. Pre-flight gate

```sh
lake build && lake lint && lake test
```

Run `lake test -- --all` if the release candidates touch a slow suite's ground. The release workflow runs `lake test`
on all four legs, so a failure you skipped locally costs a tag.

### 2. Version bump — four places, all must agree

lean-fmt is pre-1.0: breaking changes bump minor, otherwise patch. Set `X.Y.Z` in **all** of:

- `lakefile.lean` — `version := v!"X.Y.Z"`
- `LeanFmt/Basic.lean` — the `"X.Y.Z"` literal (what `lean-fmt --version` prints)
- `README.md` — the toolchain-compatibility table row `| X.Y.Z | \`vL.M.N\` |` and the Lake-dependency pin
  `@ "vX.Y.Z"`

A half-updated version passes CI and ships a binary that misreports itself.

### 3. CHANGELOG

Add a new section at the top of `CHANGELOG.md` headed `## X.Y.Z — YYYY-MM-DD` (this repository's heading format is
*not* the bracketed keep-a-changelog form — match the existing sections exactly). Compose it for a *user* audience:
an `### Upgrading` subsection first when anything requires action (a toolchain move, an output change a script might
parse), then the changes. Versions before 0.4.0 predate the file; do not backfill them.

### 4. Commit

Commit with explicit pathspecs (`lakefile.lean`, `LeanFmt/Basic.lean`, `README.md`, `CHANGELOG.md`) — never a bare
`git commit` in this shared worktree.

### 5. Tag — invariants gate

Re-verify on the commit you are tagging:

- The four version sites from step 2 all read `X.Y.Z`.
- `CHANGELOG.md`'s top section heading is `## X.Y.Z — <date>`.
- CI is green on that commit.

**Confirm with the human, then push the tag:**

```sh
git tag -a vX.Y.Z -m "lean-fmt vX.Y.Z"
git push origin vX.Y.Z
gh run watch --workflow=release.yml
```

### 6. Post-publish

- Confirm the GitHub Release shows four tarballs plus a `SHA256SUMS` whose line count equals the tarball count (the
  publish step asserts this; a mismatch kills the run before upload).
- Smoke the installer path: `install.sh` greps `SHA256SUMS` per platform — check the release renders correctly for at
  least one target.

## When a release fails mid-run

The workflow is safe to re-drive: `gh release create` is guarded by `gh release view`, and uploads use `--clobber`.
Fix the cause, then either re-run the failed jobs on the same run or dispatch the workflow manually with the same tag
name. If the tag itself was wrong (wrong commit, wrong version), delete it (`git push origin :vX.Y.Z` plus the GitHub
release) only with explicit human confirmation — a moved tag breaks every consumer who pinned it.
