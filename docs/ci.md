# Running lean-fmt in CI

**Audience: projects that use lean-fmt.** Installing the dependency is covered in `README.md`
§"Install". This guide covers CI: the recipes, what to cache between runs, and what upgrading
changes.

Every `lean-fmt` and `lake` command below is executed by lean-fmt's own test suite against a real
consuming project, so a recipe that stops working fails a test. The workflow YAML around those
commands is reviewed rather than run — nobody uploads to code scanning from a test suite.

## Exit codes are the whole interface

```
0  clean, or output successfully applied
1  findings, proposed changes, broken sources, or rejected fixes
2  a request, workspace, or infrastructure failure prevented a trustworthy result
```

Four consequences a CI job depends on:

- **The exit code is independent of `--output-format`.** A job never parses a report to learn
  whether it succeeded. Choosing SARIF over text changes what the report looks like, nothing else.
- **A broken pipe keeps the run's own exit code.** `lean-fmt check … | head` still exits 1 when
  there were findings, so pipelines are safe and cannot silence CI.
- **1 and 2 mean different things; keep them apart.** Exit 1 is the tool working and disagreeing
  with your source. Exit 2 is the tool not having run properly: a bad root, a missing named file,
  an unresolvable workspace. A job that collapses them reports a broken runner as a lint failure.
- **A command lean-fmt cannot lay out does not fail the file.** That command keeps its original
  bytes and the rest of the file formats normally. The run says so: a trailer line, a
  `verbatim_commands=` field under `--statistics`, and `verbatimCommands` on the JSON report and on
  each file. Several commands in one file may degrade together. Only a failure no command owns —
  the header, the terminal tail, the source map — exits 2. To fail those files loudly instead,
  assert `verbatimCommands` is `0`; the field is there so the choice is yours, not the tool's.

To see what was lost, read `degradations` on the JSON report: one entry per command
`verbatimCommands` counts, with the 1-based `line`, the syntax `kind`, the `gate` that refused the
layout, and the `detail` it refused with. The count says a file lost a layout; `kind` says which
shape lean-fmt could not spell, which is what a bug report needs. It is on the JSON report only —
SARIF results are findings about your code, and a degradation is not one.
`LEAN_FMT_STRICT_LAYOUT=1` turns every degradation back into a whole-file exit 2; that is for
bisecting a defect, not for a job.

## Recipe 1 — the minimal job

What `.github/workflows/ci.yml` in this repository already runs, and the recipe to start from. It
needs `lintDriver` configured in the consuming package (`README.md` §"In another project").

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
lean-fmt-specific step appears. Findings exit 1 and fail the job; infrastructure failures exit 2
and also fail it, distinguishably in the log.

## Recipe 2 — SARIF into GitHub code scanning

`--output-format sarif` emits a 2.1.0 log aimed at GitHub code scanning: `columnKind:
unicodeCodePoints`, `originalUriBaseIds` carrying `%SRCROOT%`, percent-encoded relative `uri`s,
and a `helpUri` per rule. It validates against the schema vendored at
`tests/fixtures/reporting/sarif-schema-2.1.0.json`, so an example can be checked offline.

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

All four details are load-bearing:

- **The upload runs unconditionally.** A clean run still writes a complete, schema-valid SARIF log
  with an empty `results` array. Uploading it tells code scanning the previous alerts are
  resolved; skipping the upload on success leaves stale alerts open forever.
- **The `hashFiles` guard is not decoration.** On exit 2 no report is written at all. Without the
  guard, `upload-sarif` fails on a missing file and masks the real error.
- **`--output-file` is pre-checked and atomic.** A missing parent directory is an exit-2 error
  before analysis runs, and the file is renamed into place so a reader never sees a truncated log.
- **The status is captured, not inherited.** `set +e` plus an explicit `$GITHUB_OUTPUT` write
  keeps exit 1 and exit 2 distinguishable in the final step. `continue-on-error: true` on the run
  step would collapse them.

## Recipe 3 — pull requests, changed files only

`--changed-since REV` selects the files this branch changed since `REV`, comparing against the
merge base.

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

`fetch-depth: 0` is required: a merge base not in the clone cannot be resolved.

Selection provenance goes to **stderr**, not into the JSON report:

```
lean-fmt: changed-file selection: HEAD~1...HEAD (merge base)
lean-fmt: resolved base: 7af9fef6fa7564af26b238f4123cf47b17fc9192
lean-fmt: 3 changed path(s) selected; this run covers that subset, not the whole project
```

`RunReport` is the frozen JSON compatibility surface and does not carry provenance. An integration
that needs it machine-readably parses stderr.

A run that selects nothing exits 0 with a notice and never analyzes anything:

```
lean-fmt: no changed Lean sources under .
```

This matters because an empty file list means "the whole project" everywhere else in the CLI. Any
wrapper that reimplements selection must preserve the distinction, or a no-op commit will lint —
or with `check --fix`, rewrite — the entire tree.

`--staged` is the same mechanism against the index rather than a revision, which is what a
pre-commit hook wants. `--changed` compares against `HEAD` and adds untracked files.

## Recipe 4 — generic CI, exit codes only

Nothing above is GitHub-specific except the SARIF consumer and the `github` output format. On any
other runner, exit codes alone suffice:

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

`junit` suits any runner with a JUnit XML collector. `concise` (`path:line:col: CODE message`)
suits one that scrapes logs. `github` emits workflow annotation commands and is meaningless
elsewhere.

Pair formats with modes. The four finding-shaped formats — `concise`, `github`, `sarif`, `junit` —
are rejected for `format --diff` at parse time, with exit 2:

```
--output-format sarif is not available for diff; diff reports a patch, not findings
```

`format --diff` produces a patch, not a finding set, so an empty SARIF log from it would read as
"clean". Only `text` and `json` are available there.

One other check worth a CI step:

```sh
lake exe lean-fmt docs --check     # rule documentation matches the rule catalog
```

`docs --check` exits 1 on drift.

## Caching between runs

lean-fmt keeps successful semantic results in `.lean-fmt-cache/` at the project root. Cache it
alongside `.lake` under one key:

```yaml
- uses: actions/cache@v4
  with:
    path: |
      .lake
      .lean-fmt-cache
    key: lean-fmt-${{ runner.os }}-${{ hashFiles('lean-toolchain', 'lakefile.lean', 'lake-manifest.json') }}
```

The cache's identity takes the formatter binary's content, not its path or mtime, so rebuilding or
reinstalling lean-fmt keeps every entry as long as the bytes are the same. The key above covers
what invalidates the cache wholesale anyway, so a bump re-populates rather than silently missing:

- **the toolchain** — identity pins the Lean version string and git hash, so a `lean-toolchain`
  bump invalidates everything;
- **the ordered Lake environment** — search-path precedence and dependency build traces, so a
  `lake update` that moves any dependency invalidates everything;
- **`[format]` configuration** — `line-width` changes the canonical bytes, so an entry recorded at
  another width is rightly a miss.

`[lint]` keys (`select`, `ignore`, `per-file-ignores`) are **not** part of cache identity. Every
rule's findings are computed once and rule selection chooses which to report, so changing which
rules a job reports never invalidates an entry. A repository can run a strict job and a lenient job
against the same warm cache.

Per entry, the source's own bytes and its dependency closure are checked, so editing a file misses
only that file's entry. An invalidated index is orphaned, not deleted; `lake exe lean-fmt clean`
removes the whole `.lean-fmt-cache` directory and is idempotent. `--no-cache` neither reads nor
writes it, which is what a job measuring cold performance wants.

## Upgrading in CI

Install itself is `README.md` §"Install"; the release policy is `docs/maintenance.md`. What a CI
setup needs to know about upgrades is three things:

1. **Pin the `require`, and commit `lake-manifest.json`.** `require` without a revision follows
   the default branch, which makes CI non-reproducible: a push to lean-fmt changes your build with
   no commit of yours. A commit SHA works too, when you want a fix that landed after a tag. The
   manifest is what makes a CI run reproduce a local one.
2. **Move the pin with `lake update «lean-fmt»`, then read the manifest diff.** `lake update`
   accepts a package name it does not recognize and exits 0 without doing anything, so a typo
   reports success and changes nothing. A bad *revision* fails loudly; the hazard is the package
   name. `git diff lake-manifest.json` is the check.
3. **Expect new findings and a cold cache, nothing else.** A new or widened rule reports on source
   that passed before — pin selection explicitly (`[lint] select`) if a job must not acquire new
   rules on upgrade. The binary change orphans every cache entry, so the first run after an
   upgrade pays full cost: expected, not a regression. Your source is never touched by an upgrade
   — only `format` and `check --fix` write, and only when you run them.

**Toolchain bumps.** lean-fmt's `lean-toolchain` and the consumer's must match: Lean's ABI is not
stable across releases, and the compiler plugin, if you use it, is a shared library loaded into
your compiler. Because the tag names the toolchain, a bump is one edit in two places that have to
agree:

```sh
# 1. move lean-toolchain, and move the require tag to the same string
# 2. re-resolve and rebuild from clean
lake update
lake build
# 3. confirm the integration still resolves
lake check-lint
lake exe lean-fmt compiler build
```

Lake's `plugins` field is still officially experimental and its target-key syntax has changed more
than once, so step 3 is not optional if you took the plugin. The bump invalidates the cache
wholesale, so no stale result survives it.
