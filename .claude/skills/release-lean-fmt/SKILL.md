---
name: release-lean-fmt
description: Cut a lean-fmt release — one tag per toolchain, named exactly as lean-toolchain (v4.34.0-rc1, not semver). Use when releasing lean-fmt, cutting or pushing a release tag, updating the version in lakefile.lean and LeanFmt/Basic.lean, writing the CHANGELOG section for a toolchain, or recovering from a failed release run.
---

# Release lean-fmt

**The tag is the toolchain.** A release is tagged exactly as the `lean-toolchain` it was built against — `v4.34.0-rc1`,
not a semantic version. A consumer requires the tag matching their own toolchain and never consults a compatibility
table. That contract only holds because `.github/workflows/release.yml`'s `verify-tag` job asserts it; do not weaken
that job.

**Nothing is packaged or uploaded.** There are no prebuilt binaries and no `install.sh`. lean-fmt is a Lake dependency
built from source against the consumer's own compiler — which is what the plugin and the cache facet require anyway,
since a plugin is a shared library loaded into that compiler. Pushing the tag fires a full `lake test` gate on four
platform legs and then creates a GitHub Release carrying notes and nothing else. NEVER build and distribute a binary
locally; a build that skips the four-leg gate is not a release.

A botched tag is not permanent, but a tag that consumers and Lake manifests already pin is costly to move. Treat the tag
push as irreversible.

## When there is a release to cut

One per toolchain, at the point the tree is good on it. Between toolchains there is no second version axis — a fix that
lands after a tag is picked up by consumers pinning a commit SHA, or by the next toolchain's tag. Do not invent
`v4.34.0-rc1-2`. If a fix genuinely cannot wait for the next Lean release, say so and decide deliberately; the answer is
usually that Lean's cadence is faster than the wait.

## Steps

Steps 1–4 are reversible. Step 5 (tag push) is not — **stop and get explicit human confirmation first.**

### 1. Pre-flight gate

```sh
lake build && lake lint && lake test
```

Run `lake test -- --all` if the candidate touches a slow suite's ground. The release workflow runs `lake test` on all
four legs, so a failure you skipped locally costs a tag.

### 2. Version — three places, all must agree

The version string is the toolchain without its leading `v`. For `leanprover/lean4:v4.34.0-rc1` it is `4.34.0-rc1`. Set
it in:

- `lean-toolchain` — the source of truth, moved by the `bump-toolchain` skill, not here
- `lakefile.lean` — `version := v!"4.34.0-rc1"`
- `LeanFmt/Basic.lean` — the literal `lean-fmt --version` prints

The boundary suite's `package-identity` case ties the last two together; `verify-tag` ties them to `lean-toolchain` and
to the tag. A half-updated version fails the release rather than shipping a binary that misreports itself.

### 3. CHANGELOG

`CHANGELOG.md`'s top section is headed `## <version> — YYYY-MM-DD`, matching the existing sections exactly (this
repository does not use the bracketed keep-a-changelog form). Compose it for a *user* audience: an `### Upgrading`
subsection first when anything requires action, then the changes.

Because there is one release per toolchain, a fix landing after a tag appends to that toolchain's existing section
rather than opening a new one. Versions before 0.4.0 predate the file; do not backfill them.

### 4. Commit

Commit with explicit pathspecs (`lakefile.lean`, `LeanFmt/Basic.lean`, `CHANGELOG.md`, and `README.md` if its example
tag moved) — never a bare `git commit` in this shared worktree.

### 5. Tag — invariants gate

Re-verify on the commit you are tagging:

- `lean-toolchain`, `lakefile.lean` and `LeanFmt/Basic.lean` agree, and the tag is `v` plus that string.
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
