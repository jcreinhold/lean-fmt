---
name: release-lean-fmt
description: Cut a lean-fmt release — toolchain tags and explicitly approved formatter-only repair tags. Use when releasing lean-fmt, cutting or pushing a release tag, updating the version in lakefile.lean and LeanFmt/Basic.lean, writing the CHANGELOG section for a toolchain, or recovering from a failed release run.
---

# Release lean-fmt

The first release for a Lean toolchain uses its exact tag. An explicitly approved formatter-only
repair appends `-fmt.N`, with `N` a positive integer without leading zeros. For example,
`v4.36.0-fmt.1` still requires Lean `v4.36.0`. The release verifier checks the exact toolchain
prefix and matches the tag to the formatter version.

**Nothing is packaged or uploaded.** There are no prebuilt binaries and no `install.sh`. lean-fmt is a Lake dependency
built from source against the consumer's own compiler — which is what the plugin and the cache facet require anyway,
since a plugin is a shared library loaded into that compiler. Pushing the tag fires a full `lake test` gate on three
platform legs and then creates a GitHub Release carrying notes and nothing else. NEVER build and distribute a binary
locally; a build that skips the three-leg gate is not a release.

A botched tag is not permanent, but a tag that consumers and Lake manifests already pin is costly to move. Treat the tag
push as irreversible.

## When there is a release to cut

Use a commit SHA for an unreleased fix. If the user approves a formatter-only repair release,
use the next `-fmt.N` tag and preserve existing tags.

## Steps

Steps 1–4 are reversible. Step 5 (tag push) is not — **stop and get explicit human confirmation first.**

### 1. Pre-flight gate

```sh
lake build && lake lint && lake test
```

Run `lake test -- --all` if the candidate touches a slow suite's ground. The release workflow runs `lake test` on all
three legs, so a failure you skipped locally costs a tag.

### 2. Version

The formatter version is the release tag without its leading `v`. Set it in `lakefile.lean`
and `LeanFmt/Basic.lean`, and update the README dependency and install examples. Keep the
root and manual toolchain pins and the Verso pin aligned to the actual Lean release.

The boundary suite checks that the package, CLI, and README versions agree. The workflow
verifies that the release tag matches the package version and names the pinned compiler.
Lake orders `4.36.0-fmt.1` below `4.36.0` as a prerelease version. Consumers should pin the
exact Git tag. GitHub's prerelease flag is separate from Lake's version ordering.

### 3. CHANGELOG

`CHANGELOG.md`'s top section is headed `## <version> — YYYY-MM-DD`, matching the existing sections exactly (this
repository does not use the bracketed keep-a-changelog form). Compose it for a *user* audience: an `### Upgrading`
subsection first when anything requires action, then the changes.

Start a new section for each release tag. Versions before 0.4.0 predate the file.

### 4. Commit

Commit with explicit pathspecs (`lakefile.lean`, `LeanFmt/Basic.lean`, `CHANGELOG.md`, and `README.md` if its example
tag moved) — never a bare `git commit` in this shared worktree.

### 5. Tag — invariants gate

Re-verify on the commit you are tagging:

- The tag names the exact `lean-toolchain` with an optional repair suffix. Its version without `v`
  matches the package, CLI, and README pin.
- `CHANGELOG.md`'s top section heading is `## <version> — <date>`.
- CI is green on that commit. It cannot be until the branch is pushed, so push the branch and wait for green before
  tagging — never tag against a local-only run.

**Confirm with the human, then push the tag:**

```sh
git tag -a v4.34.0-rc1 -m "lean-fmt for Lean 4.34.0-rc1"
git push origin v4.34.0-rc1
gh run watch --workflow=release.yml
```

### 6. Post-publish

Confirm the Release page exists with generated notes. There are no assets to check. Then smoke the consumer path on a
real project — require the new tag, `lake update «lean-fmt»`, `lake exe lean-fmt --version` — because that path, not a
tarball, is now what every user takes.

## When a release fails mid-run

Safe to re-drive: `gh release create` is guarded by `gh release view`. Fix the cause, then re-run the failed jobs or
dispatch the workflow manually with the same tag name. If the tag itself was wrong (wrong commit, wrong toolchain),
delete it (`git push origin :vX.Y.Z` plus the GitHub release) only with explicit human confirmation — a moved tag breaks
every consumer who pinned it.
