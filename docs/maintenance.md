# How lean-fmt is maintained

One question: what happens when
Lean moves, and which parts of the answer are automated.

lean-fmt is maintained by one person. What follows is what has been automated so that depending on it does not depend on
that person having a free evening.

## The release contract

**One release per Lean toolchain, tagged exactly as the toolchain**: `v4.34.0-rc1` serves `leanprover/lean4:v4.34.0-rc1`
and nothing else. Require the tag spelled like your `lean-toolchain` and the pairing is right. There is no compatibility
table and no version to choose.

This is forced, not chosen. lean-fmt loads your project's `.olean`s, and those load only in the compiler that wrote
them, so there is exactly one correct answer per toolchain. Lake is told the same thing directly: the package sets
`fixedToolchain := true`, so a consumer on a different toolchain fails at resolution rather than somewhere deep in a
build.

**Release candidates get tags too.** An rc is the window in which an upstream change can still be questioned rather than
only absorbed, so lean-fmt tracks rcs rather than waiting for stable.

**There is no patch axis.** A fix landing after a tag is picked up by pinning a commit SHA, or by the next toolchain's
tag. `lake-manifest.json` records whatever you resolved, so a SHA pin is as reproducible as a tag pin.

**Nothing is distributed as a binary.** lean-fmt is built from source against your compiler, which is what the compiler
plugin and cache facet require anyway. Releases through `v0.7.1` shipped tarballs; those tags still exist and still
work.

## What runs without anyone asking

| when | what | outcome |
| --- | --- | --- |
| weekly | `next-toolchain` probe against the newest Lean release, rcs included | three signals: does it build, did the vendored `Std.Format` region move, do any canonical bytes change |
| weekly, probe green | `bump` opens a pull request | `lean-toolchain` and every site that must agree with it, gated by `lake build`, `lake lint` and `lake test` in the same run |
| weekly, probe red | `adaptation-alert` opens one issue for that candidate | a work item, labelled `toolchain-probe`, not started |
| weekly | the flake-hunt: the default suite set twice, plus every slow suite | an intermittent failure nobody exercises is one everybody ships |
| monthly | `corpus` runs lean-fmt over all of mathlib4 | counts published to the run summary, per-file JSON uploaded, `rejected` and `infrastructure_failures` gated at zero |
| every push and PR | the sharded suite matrix | the 40 suites, one of which asserts every recorded upstream defect still reproduces |
| on a `v*` tag | `verify-tag`, then the full gate on four platforms | a Release page; nothing is packaged |

A bump that builds and moves no canonical bytes has nothing left to decide, so it arrives as a reviewable pull request
rather than a note in a summary somebody reads next month. Most Lean releases are that kind.

## What a person decides

The automation stops short of four things, because each needs a judgement a green check cannot carry:

- **Adapting to a moved internal.** When the probe goes red, something upstream changed under us. The alert names which
  of the three signals broke; `docs/toolchain-upgrade.md` is the checklist and the `bump-toolchain` skill is the
  procedure. Nothing starts this work automatically.
- **Accepting a corpus change.** A drop in `verbatim_commands` matched by a rise in `rejected` has moved defects rather
  than fixed them. Only `rejected` and `infrastructure_failures` are gated; the rest is reported for a person to read.
- **Whether an upstream change is a defect to report or a contract to adopt.** `docs/upstream-defects/` holds twelve
  reproductions that are the material for that decision, and the `upstream-defects` suite asserts that each one still
  reproduces. A red `upstream-defects` is the good kind of red: it means Lean fixed something this project pays for, and
  the failure message names the mechanism to delete. It is also the one signal that separates that case from "upstream
  broke us", which the toolchain probe alone cannot tell apart.
- **The tag push.** Releases are not automatic. A tag that consumers pin is costly to move, so it stays a deliberate
  act.

## If a release is late

The probe raises an issue for every candidate lean-fmt does not yet serve, so a gap is visible rather than silent: check
the `toolchain-probe` label before assuming a toolchain is unsupported.

Meanwhile you are not stuck. `main` carries fixes that landed after the last tag, and a commit SHA pins as reproducibly
as a tag does:

```lean
require «lean-fmt» from git "https://github.com/jcreinhold/lean-fmt" @ "<sha>"
```

The one thing that cannot be worked around is a toolchain lean-fmt has never built against. That needs the adaptation
the alert is asking for.

## Where the durable records are

Reasoning that is not recoverable from code or tests is gone, so it is written down. In order of authority: built code,
then the suites under `tests/`, then module docstrings in `LeanFmt/`, then `docs/`. When two records disagree, the
disagreement and its resolution get written down rather than quietly settled.

- `AGENTS.md` — the product constraints, the build and check commands, and which record wins.
- `docs/toolchain-upgrade.md` — the bump checklist, addressed to whoever is doing one.
- `docs/upstream-defects/` — twelve toolchain-only reproductions, one file per defect, each recording what a fix
  upstream would let us delete.
- `docs/flaky-tests.md` — read before re-running an intermittent failure; a retry on an unlogged signature trades a bug
  report for a coin flip.
- `CHANGELOG.md` — one section per toolchain, written for users.
