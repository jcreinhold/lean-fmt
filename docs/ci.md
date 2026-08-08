# Running lean-fmt in CI

**Audience: projects that use lean-fmt.** Taking lean-fmt as a dependency is covered in `README.md` §"In another
project". This guide covers CI: the recipes, what to cache between runs, and what pinning and upgrading change.

Every `lean-fmt` and `lake` command below is executed by lean-fmt's own test suite against a real consuming project, so
a recipe that stops working fails a test. The workflow YAML around those commands is reviewed rather than run — nobody
uploads to code scanning from a test suite.

## Exit codes are the whole interface

```
0  clean, or output successfully applied
1  findings, proposed changes, broken sources, or rejected fixes
2  a request, workspace, or infrastructure failure prevented a trustworthy result
```

Three consequences a CI job depends on.

**The exit code is independent of `--output-format`.** A job never parses a report to learn whether it succeeded.
Choosing SARIF over text changes what the report looks like, nothing else.

**A broken pipe keeps the run's own exit code.** `lean-fmt check … | head` still exits 1 when there were findings, so a
recipe may use pipelines freely without turning a pipe into a way to silence CI.

**1 and 2 mean different things; keep them apart.** Exit 1 is the tool working and disagreeing with your source. Exit 2
is the tool not having run properly — a bad root, a missing named file, an unresolvable workspace. A job that collapses
them reports a broken runner as a lint failure.

## Recipe 1 — the minimal job

This is what `.github/workflows/ci.yml` in this repository already runs, and the recipe to start from. It needs
`lintDriver` configured in the consuming package (`README.md` §"In another project").

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

`lean-action` probes `lake check-lint` and runs `lake lint` when a driver is configured, so no lean-fmt-specific step
appears. Findings exit 1 and fail the job; infrastructure failures exit 2 and also fail it, distinguishably in the log.

## Recipe 2 — SARIF into GitHub code scanning

`--output-format sarif` emits a 2.1.0 log aimed at GitHub code scanning: `columnKind: unicodeCodePoints`,
`originalUriBaseIds` carrying `%SRCROOT%`, percent-encoded relative `uri`s, and a `helpUri` per rule. It validates
against the schema vendored at `tests/fixtures/reporting/sarif-schema-2.1.0.json`, so an example can be checked offline.

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
          lake exe lean-fmt check \
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

Four details worth knowing.

**The upload step runs unconditionally, and that is the point.** A clean run still writes a complete, schema-valid SARIF
log with an empty `results` array. Uploading it tells code scanning the previous alerts are resolved; skipping the
upload on success leaves stale alerts open forever.

**The `hashFiles` guard is not decoration.** On exit 2 no report is written at all — the run failed before it had a
report to write. Without the guard, `upload-sarif` fails on a missing file and masks the real error.

**`--output-file` is pre-checked and atomic.** A missing parent directory is an exit-2 error *before* analysis runs, not
after four minutes of work, and the file is renamed into place so a reader never sees a truncated log.

**The status is captured, not inherited.** `set +e` plus an explicit `$GITHUB_OUTPUT` write keeps exit 1 and exit 2
distinguishable in the final step. `continue-on-error: true` on the run step would collapse them.

## Recipe 3 — pull requests, changed files only

`--changed-since REV` selects the files this branch changed since `REV`, comparing against the merge base.

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
      - run: lake exe lean-fmt check --changed-since origin/${{ github.base_ref }}
```

`fetch-depth: 0` is required. GitHub's default checkout is shallow, and a merge base not in the clone cannot be
resolved.

Selection provenance goes to **stderr**, not into the JSON report:

```
lean-fmt: changed-file selection: HEAD~1...HEAD (merge base)
lean-fmt: resolved base: 7af9fef6fa7564af26b238f4123cf47b17fc9192
lean-fmt: 3 changed path(s) selected; this run covers that subset, not the whole project
```

`RunReport` is the frozen JSON compatibility surface and does not carry provenance. An integration that needs it
machine-readably parses stderr.

**A run that selects nothing exits 0 with a notice and never analyzes anything:**

```
lean-fmt: no changed Lean sources under .
```

This matters because an empty file list means "the whole project" everywhere else in the CLI. Any wrapper that
reimplements selection must preserve the distinction, or a no-op commit will lint — or with `check --fix`, rewrite — the
entire tree.

`--staged` is the same mechanism against the index rather than a revision, which is what a pre-commit hook wants.
`--changed` compares against `HEAD` and adds untracked files.

## Recipe 4 — generic CI, exit codes only

Nothing above is GitHub-specific except the SARIF consumer and the `github` output format. On any other runner, exit
codes alone suffice:

```sh
#!/usr/bin/env bash
set -euo pipefail

lake build

set +e
lake exe lean-fmt check --output-format junit --output-file lean-fmt.xml
status=$?
set -e

case $status in
  0) echo "clean" ;;
  1) echo "lean-fmt reported findings"; exit 1 ;;
  *) echo "lean-fmt could not produce a trustworthy result (exit $status)"; exit $status ;;
esac
```

`junit` suits any runner with a JUnit XML collector. `concise` (`path:line:col: CODE message`) suits one that scrapes
logs. `github` emits workflow annotation commands and is meaningless elsewhere.

Pair formats with modes. The four finding-shaped formats — `concise`, `github`, `sarif`, `junit` — are **rejected for
`format --diff`** at parse time, with exit 2:

```
--output-format sarif is not available for diff; diff reports a patch, not findings
```

`format --diff` produces a patch, not a finding set, so an empty SARIF log from it would read as "clean". Only `text`
and `json` are available there.

One other check worth a CI step:

```sh
lake exe lean-fmt docs --check     # rule documentation matches the rule catalog
```

`docs --check` exits 1 on drift.

## Caching between runs

lean-fmt keeps successful semantic results in `.lean-fmt-cache/` at the project root. Caching it across CI runs is
worthwhile and needs no special handling.

**The cache's identity takes the formatter binary's content**, not its path or modification time. So rebuilding lean-fmt
from source, or reinstalling it somewhere else, keeps every entry as long as the bytes are the same. Hashing the binary
costs about 40 ms and is paid once per build; later runs read the memoized answer from
`.lean-fmt-cache/formatter-identity.json`.

Cache `.lake` alongside `.lean-fmt-cache` under one key. A restored `.lake` is worth having on its own:

```yaml
- uses: actions/cache@v4
  with:
    path: |
      .lake
      .lean-fmt-cache
    key: lean-fmt-${{ runner.os }}-${{ hashFiles('lean-toolchain', 'lakefile.lean', 'lake-manifest.json') }}
```

The key covers what invalidates the cache wholesale anyway, so a bump re-populates rather than silently missing:

- **the toolchain** — identity pins the Lean version string and git hash, so a `lean-toolchain` bump invalidates
  everything;
- **the ordered Lake environment** — search-path precedence and dependency build traces, so a `lake update` that moves
  any dependency invalidates everything;
- **`[format]` configuration** — `line-width` changes the canonical bytes, so an entry recorded at another width is
  rightly a miss.

`[lint]` keys — `select`, `ignore`, `per-file-ignores` — are **not** part of cache identity. Every rule's findings are
computed once and rule selection chooses which to report, so changing which rules a job reports never invalidates an
entry. A repository can run a strict job and a lenient job against the same warm cache.

Per entry, the source's own bytes and its dependency closure are checked, so editing a file misses only that file's
entry.

An invalidated index is orphaned, not deleted; `lake exe lean-fmt clean` removes the whole `.lean-fmt-cache` directory
and is idempotent. `--no-cache` neither reads nor writes it, which is what a job measuring cold performance wants.

## Installing and upgrading

Two ways in, by what the job needs. A job that only runs the **CLI** can skip the from-source build — the release
binaries are statically self-contained:

```sh
curl -sSfL https://raw.githubusercontent.com/jcreinhold/lean-fmt/main/install.sh | sh
```

A job that uses the **compiler plugin or the cache facet** cannot: a plugin must be built against the consuming
project's own toolchain, so that integration still takes `lean-fmt` as an ordinary Lake dependency and builds it from
source. `README.md` §"In another project" covers that dependency; the rest of this section is about the pin.

**Pin a revision.** `require` without a revision follows the default branch, which makes CI non-reproducible: a push to
lean-fmt changes your build with no commit of yours.

```lean
require «lean-fmt» from git "https://github.com/jcreinhold/lean-fmt" @ "<commit-sha-or-tag>"
```

Releases are tagged (`v0.1.0` and later), so a tag is the pin to use; a commit SHA works the same way. The resolved
revision lands in `lake-manifest.json` either way. **Commit that file.** It is what makes a CI run reproduce a local
one.

**Moving the pin.** Edit the revision in the lakefile, then `lake update «lean-fmt»` to re-resolve that one dependency
and rewrite the manifest; bare `lake update` re-resolves everything. The manifest records the package under its
guillemeted name, which is the spelling to pass.

Read the manifest diff afterwards rather than trusting the command's exit code. `lake update` accepts a package name it
does not recognize and exits 0 without doing anything, so a typo reports success and changes nothing. A bad *revision*
does fail loudly — `lake update` exits 1 when the pinned commit cannot be read — so the hazard is specifically the
package name, not resolution in general. `git diff lake-manifest.json` is the check.

Expect three things to change:

1. **New or changed findings.** A new or widened rule reports on source that passed before. `lake exe lean-fmt rules`
   lists what is active; `lean-fmt explain RULE` says what one does. Pin selection explicitly (`[lint] select`) if a job
   must not acquire new rules on upgrade.
2. **A cold cache.** The binary changes, so every entry is orphaned. The first run after an upgrade pays full cost —
   expected, not a regression.
3. **Nothing about your source.** `check` and the `format` previews never write. Only `format` and `check --fix` do, and
   only when you run them.

**Toolchain bumps.** lean-fmt's `lean-toolchain` and the consumer's must match. Lean's ABI is not stable across
releases, and the compiler plugin — if you use it — is a shared library loaded into your compiler. A mismatch is not a
soft failure. On a bump:

```sh
# 1. move both pins to the same toolchain
# 2. re-resolve and rebuild from clean
lake update
lake build
# 3. confirm the integration still resolves
lake check-lint
lake exe lean-fmt compiler build
```

Lake's `plugins` field is still officially experimental and its target-key syntax has changed more than once, so step 3
is not optional if you took the plugin. A consuming project that uses the plugin should treat a toolchain bump as an
event to test, not a version-string edit.

The bump invalidates the cache wholesale, so no stale result survives it.
