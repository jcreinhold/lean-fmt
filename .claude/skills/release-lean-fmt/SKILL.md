---
name: release-lean-fmt
description: Cut a lean-fmt release (version bump, CHANGELOG, tag) that publishes the workspace crates. Use when releasing lean-fmt, publishing to crates.io, bumping the workspace version for a release, or cutting a vX.Y.Z tag.
---

# Release lean-fmt

This skill is the release checklist plus the cross-file invariants that only bite *after* you tag, when
it is too late: **crates.io versions are immutable**, so a botched publish burns a version permanently.

lean-fmt publishes **seven crates** off a single shared workspace version:
`lean-fmt-edit`, `lean-fmt-runtime`, `lean-fmt-diagnostics`, `lean-fmt-worker`, `lean-fmt-project`,
`lean-fmt-worker-child`, `lean-fmt-cli` (the last produces the `lean-fmt` binary). All share
`[workspace.package].version`.

> **Prerequisites not yet in the repo.** As of this writing lean-fmt has **no `CHANGELOG.md`**, **no
> `release.yml`**, **no `docs/release.md`**, and `.github/workflows/ci.yml` is a placeholder. The
> **target** model below is CI-tag-triggered publish (preferred once the workflow exists); until it does,
> use the **local publish fallback** at the end. Create the missing infra as its own change before
> relying on the CI path — do not improvise it mid-release.

Do the reversible prep (steps 1–4) freely. The tag push (step 5) is irreversible — **stop and get
explicit human confirmation before running it.**

## 1. Pre-flight gate

Run the same checks CI runs, and stop on any failure:

```sh
scripts/fmt.sh
scripts/lint.sh
scripts/test.sh
scripts/lean.sh
```

## 2. Version bump (one source of truth)

Pick the new `X.Y.Z` (patch unless the change is breaking/feature — it is pre-1.0, so breaking changes
bump the minor). In the root `Cargo.toml`, set `[workspace.package].version = "X.Y.Z"`; the seven crates
inherit it via `version.workspace = true`. If any `[workspace.dependencies]` path entry pins a `version`,
bump it to match.

The tag and the workspace version must agree: tag `vX.Y.Z` ⇒ `version = "X.Y.Z"`. A half-updated version
must fail the release, so keep them in lockstep.

## 3. CHANGELOG

Move the `## [Unreleased]` entries into a new `## [X.Y.Z]` section (compose fresh if empty). The heading
text must match the tag **exactly**: tag `v0.2.0` → heading `## [0.2.0]`. The release notes are extracted
from that section verbatim, so a missing heading is a hard failure.

## 4. Commit the prep

Commit the version bump + CHANGELOG together on a release branch, open a PR, and merge after CI is green.

## 5. Tag — the irreversible step

Before tagging, re-verify on the merge commit:

- `git rev-parse --abbrev-ref HEAD` is `main` and up to date.
- `[workspace.package].version` in `Cargo.toml` matches the intended `X.Y.Z`.
- `CHANGELOG.md` has a `## [X.Y.Z]` heading.

**Confirm with the human, then push the tag:**

```sh
git tag -s vX.Y.Z -m "lean-fmt vX.Y.Z"   # -s signed (preferred), or -a annotated
git push origin vX.Y.Z
```

Under the target CI model this fires `release.yml`, which re-runs the gate and publishes each crate in
dependency order. Tags containing `-` (e.g. `vX.Y.Z-rc.1`) are prereleases.

## 6. Post-publish

- `cargo search lean-fmt` — all seven crates show the new version.
- Confirm the docs.rs builds succeeded.
- Add a fresh `## [Unreleased]` heading to the top of `CHANGELOG.md`.

## Publish order (dependency DAG)

crates.io rejects a crate whose path dependencies are not yet published, so publish leaves first. The
order that respects the internal DAG:

1. `lean-fmt-edit`
2. `lean-fmt-runtime`
3. `lean-fmt-diagnostics`  (→ edit)
4. `lean-fmt-worker`       (→ edit, runtime)
5. `lean-fmt-project`      (→ diagnostics, edit, worker)
6. `lean-fmt-worker-child` (runtime dep is external `lean-rs-worker-child`; publish before cli)
7. `lean-fmt-cli`          (→ diagnostics, project, runtime, worker)

Re-verify this order against the manifests before publishing — a new internal edge changes it.

## Local publish fallback (until `release.yml` exists)

Only when CI publish is unavailable. `cargo publish` is per-crate and irreversible; publish strictly in
the order above, waiting for each to land in the index before the next:

```sh
for c in lean-fmt-edit lean-fmt-runtime lean-fmt-diagnostics lean-fmt-worker \
         lean-fmt-project lean-fmt-worker-child lean-fmt-cli; do
  cargo publish -p "$c"   # wait for index propagation between crates
done
```

Never use `--allow-dirty`. If the run dies partway, the already-published crates keep the new version
(immutable); do **not** bump — resume from the first unpublished crate. If a crate's *contents* were
wrong (a real build break, not a propagation race), bump the patch version, repeat steps 2–5, and re-tag.
