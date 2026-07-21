# Running lean-fmt in CI

`README.md` §"Using lean-fmt in another project" says how a consuming project takes `lean-fmt` as a
dependency and what the three consumption levels are. This document says how to run it in a CI job,
what may be cached between runs, and what pinning and upgrading change.

Every command quoted here was executed against a scratch consuming repository before it was written
down; the transcripts are in `docs/projects/ruff-18-integrations/results/01-recipes.md`.

## Exit codes are the whole interface

```
0  clean, or output successfully applied
1  findings, proposed changes, broken sources, or rejected fixes
2  a request, workspace, or infrastructure failure prevented a trustworthy result
```

Three consequences a CI job depends on.

**The exit code is independent of `--output-format`.** A job never parses a report to learn whether
it succeeded. Choosing SARIF over text changes what the report looks like and nothing about the
job's status.

**A broken pipe keeps the run's own exit code.** `lean-fmt check … | head` still exits 1 when there
were findings, so a recipe may use pipelines freely without turning a pipe into a way to silence CI.

**1 and 2 mean different things and a recipe should keep them apart.** Exit 1 is the tool working
and disagreeing with your source. Exit 2 is the tool not having run properly — a bad root, a missing
named file, an unresolvable workspace. A job that collapses them reports a broken runner as a lint
failure.

## Recipe 1 — the minimal job

This is what `.github/workflows/lean_action_ci.yml` in this repository already runs, and it is the
recipe to start from. It needs `lintDriver` configured in the consuming package (`README.md`
§"Wire it into `lake lint`").

```yaml
name: CI
on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: leanprover/lean-action@v1
```

`lean-action` probes `lake check-lint` and runs `lake lint` when a driver is configured, so no
lean-fmt-specific step appears at all. Findings exit 1 and fail the job; infrastructure failures exit
2 and also fail it, distinguishably in the log.

## Recipe 2 — SARIF into GitHub code scanning

`--output-format sarif` emits a 2.1.0 log aimed at GitHub code scanning: `columnKind:
unicodeCodePoints`, `originalUriBaseIds` carrying `%SRCROOT%`, percent-encoded relative `uri`s, and a
`helpUri` per rule. It validates against the schema vendored at
`tests/reporting/sarif-schema-2.1.0.json`, so an example can be checked offline.

```yaml
permissions:
  contents: read
  security-events: write

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: leanprover/lean-action@v1
        with:
          lint: false          # this job runs lean-fmt itself, below
      - name: lean-fmt
        id: fmt
        run: |
          set +e
          lake exe lean-fmt check --root . \
            --output-format sarif --output-file lean-fmt.sarif
          echo "status=$?" >> "$GITHUB_OUTPUT"
      - uses: github/codeql-action/upload-sarif@v3
        if: always() && hashFiles('lean-fmt.sarif') != ''
        with:
          sarif_file: lean-fmt.sarif
      - name: fail on findings
        if: steps.fmt.outputs.status != '0'
        run: |
          echo "lean-fmt exited ${{ steps.fmt.outputs.status }}"
          exit 1
```

Four details, each measured rather than assumed.

**The upload step runs unconditionally, and that is the point.** A clean run still writes a complete,
schema-valid SARIF log with an empty `results` array. Uploading it is what tells code scanning the
previous alerts are resolved; skipping the upload on success leaves stale alerts open forever.

**The `hashFiles` guard is not decoration.** On exit 2 no report is written at all — the run failed
before it had a report to write. Without the guard, `upload-sarif` fails on a missing file and masks
the real error.

**`--output-file` is pre-checked and atomic.** A missing parent directory is an exit-2 error *before*
analysis runs, not after four minutes of work, and the file is renamed into place so a reader never
sees a truncated log.

**The status is captured, not inherited.** `set +e` plus an explicit `$GITHUB_OUTPUT` write keeps
exit 1 and exit 2 distinguishable in the final step. Using `continue-on-error: true` on the run step
would collapse them.

## Recipe 3 — pull requests, changed files only

`--changed-since REV` selects the files this branch changed since `REV`, comparing against the merge
base.

```yaml
jobs:
  lint-changed:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0            # --changed-since needs history, not a shallow clone
      - uses: leanprover/lean-action@v1
        with:
          lint: false
      - run: lake exe lean-fmt check --root . --changed-since origin/${{ github.base_ref }}
```

`fetch-depth: 0` is required. GitHub's default checkout is shallow, and a merge base that is not in
the clone cannot be resolved.

Selection provenance goes to **stderr**, not into the JSON report:

```
lean-fmt: changed-file selection: HEAD~1...HEAD (merge base)
lean-fmt: resolved base: 7af9fef6fa7564af26b238f4123cf47b17fc9192
lean-fmt: 3 changed path(s) selected; this run covers that subset, not the whole project
```

`RunReport` is the frozen JSON compatibility surface and does not carry provenance. An integration
that needs it machine-readably parses stderr.

**A run that selects nothing exits 0 with a notice and never analyzes anything:**

```
lean-fmt: no changed Lean sources under .
```

This matters because an empty file list means "the whole project" everywhere else in the CLI. Any
wrapper that reimplements selection must preserve the distinction, or a no-op commit will lint — or
with `fix`, reformat — the entire tree.

`--staged` is the same mechanism against the index rather than a revision, which is what a
pre-commit hook wants. `--changed` compares against `HEAD` and adds untracked files.

## Recipe 4 — generic CI, exit codes only

Nothing above is GitHub-specific except the SARIF consumer and the `github` output format. On any
other runner, exit codes alone are sufficient:

```sh
#!/usr/bin/env bash
set -euo pipefail

lake build

set +e
lake exe lean-fmt check --root . --output-format junit --output-file lean-fmt.xml
status=$?
set -e

case $status in
  0) echo "clean" ;;
  1) echo "lean-fmt reported findings"; exit 1 ;;
  *) echo "lean-fmt could not produce a trustworthy result (exit $status)"; exit $status ;;
esac
```

`junit` suits any runner with a JUnit XML collector. `concise` (`path:line:col: CODE message`) suits
one that scrapes logs. `github` emits workflow annotation commands and is meaningless elsewhere.

Pair formats with modes. The four finding-shaped formats — `concise`, `github`, `sarif`, `junit` —
are **rejected for `diff`** at parse time, with exit 2:

```
--output-format sarif is not available for diff; diff reports a patch, not findings
```

`diff` produces a patch, not a finding set, so an empty SARIF log from it would read as "clean". Only
`text` and `json` are available there.

Two other checks worth a CI step:

```sh
lake exe lean-fmt docs --check --root .   # rule documentation matches the rule catalog
lake exe lean-fmt compiler status --root . # read-only audit of artifact coverage
```

`docs --check` exits 1 on drift. `compiler status` is an audit and exits 0 whenever it could run;
read its `ready=/missing=/unbuilt=` summary rather than its status.

## Caching between runs

lean-fmt keeps successful semantic results in `.lean-fmt-cache/` at the project root. Caching it
across CI runs is worthwhile, but only under one condition that is easy to get wrong.

**Cache `.lean-fmt-cache` and `.lake` together, under the same key.** The cache's identity includes
the formatter binary's **path, size, and modification time** — not a hash of its bytes
(`ResultCache.open?`, `LeanFmt/Cache.lean`). This is deliberate: the executable statically links
Lean's runtime, so hashing it dominated every cached invocation, and a rebuild always rewrites the
file. The consequence for CI is direct — rebuilding `lean-fmt` from source on every run gives it a
new mtime and orphans every entry, even when the rebuilt bytes are identical. Measured: touching the
binary and re-running wrote a second, complete index beside the first.

So a restored `.lean-fmt-cache` only helps if the binary that produced it is restored too, with its
mtime intact. `actions/cache` unpacks with `tar` and preserves mtimes, so caching both paths under
one key works:

```yaml
- uses: actions/cache@v4
  with:
    path: |
      .lake
      .lean-fmt-cache
    key: lean-fmt-${{ runner.os }}-${{ hashFiles('lean-toolchain', 'lakefile.lean', 'lake-manifest.json') }}
```

The key covers what invalidates the cache wholesale anyway, so a bump re-populates rather than
silently missing:

- **the toolchain** — identity pins the Lean version string and git hash, so a `lean-toolchain` bump
  invalidates everything;
- **the ordered Lake environment** — search-path precedence and dependency build traces, so a
  `lake update` that moves any dependency invalidates everything;
- **`[format]` configuration** — `line-width` changes the canonical bytes, so an entry recorded at
  another width is rightly a miss.

`[lint]` keys — `select`, `ignore`, `per-file-ignores` — are **not** in cache identity. Rule
selection is a projection over one canonical result, so changing which rules a job reports never
invalidates a cache entry. A repository can run a strict job and a lenient job against the same warm
cache.

Per entry, the source's own bytes and its dependency closure are checked, so editing a file misses
only that file's entry.

An invalidated index is orphaned, not deleted; `lake exe lean-fmt clean --root .` removes the whole
`.lean-fmt-cache` directory and is idempotent. `--no-cache` neither reads nor writes it, which is
what a job measuring cold performance wants.

## Installing and upgrading

There is no prebuilt binary — Lean's ecosystem has no artifact server — so a consumer takes
`lean-fmt` as an ordinary Lake dependency and builds it from source. `README.md` §"Using lean-fmt in
another project" has the three consumption levels; this section is about the pin.

**Pin a revision.** `require` without a revision follows the default branch, which makes CI
non-reproducible: a push to lean-fmt changes your build with no commit of yours.

```lean
require «lean-fmt» from git "https://github.com/jcreinhold/lean-fmt" @ "<commit-sha-or-tag>"
```

lean-fmt publishes no release tags yet, so a commit SHA is the pin to use today. The resolved
revision lands in `lake-manifest.json` either way. **Commit that file.** It is what makes a CI run
reproduce a local one.

**Moving the pin.** Edit the revision in the lakefile, then `lake update «lean-fmt»` to re-resolve
that one dependency and rewrite the manifest; bare `lake update` re-resolves everything. The manifest
records the package under its guillemeted name, which is the spelling to pass.

Read the manifest diff afterwards rather than trusting the command's exit code. `lake update` accepts
a package name it does not recognize and exits 0 without doing anything — observed here against a
path dependency, so a typo reports success. `git diff lake-manifest.json` is the check.

Expect three things to change:

1. **New or changed findings.** A new rule, or a widened one, reports on source that passed before.
   `lake exe lean-fmt rules` lists what is active; `lean-fmt explain RULE` says what one does. Pin
   selection explicitly (`[lint] select`) if a job must not acquire new rules on upgrade.
2. **A cold cache.** The binary changes, so every entry is orphaned. The first run after an upgrade
   pays full cost — this is expected, not a regression.
3. **Nothing about your source.** `check` and `diff` never write. Only `format` and `fix` do, and
   only when you run them.

**Toolchain bumps.** lean-fmt's `lean-toolchain` and the consumer's must match. Lean's ABI is not
stable across releases, and the compiler plugin — if you use it — is a shared library loaded into
your compiler. A mismatch is not a soft failure. On a bump:

```sh
# 1. move both pins to the same toolchain
# 2. re-resolve and rebuild from clean
lake update
lake build
# 3. confirm the integration still resolves
lake check-lint
lake exe lean-fmt compiler status --root .
```

Lake's `plugins` field is still officially experimental and its target-key syntax has been revised
more than once, so step 3 is not optional if you took the plugin. A consuming project that uses the
plugin should treat a toolchain bump as an event to test, not a version-string edit.

The cache is invalidated wholesale by the bump, so no stale result survives it.
