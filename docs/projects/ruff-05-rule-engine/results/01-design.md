# RRE-SPEC — Design rule facts and contribution interfaces twice

**Verified.** The design is `notes/01-rule-facts.md`. This records what was run, what it showed, and
what changed while running it.

No product behavior changed. Two evidence files, one experiment script, and the note. `LeanFmt/` is
untouched, which is the correct footprint for a spec prompt and is what `state/next.md` declared this
prompt to be ("Module: (docs only)").

## The headline

**Rule enablement has two spellings and they disagree with each other.** `--ignore FMT001` is
honored by every mode. `leanFmt.trailingWhitespace=false` is honored by `format` and silently
dropped by `check`.

```
                                   check           format
  --ignore FMT001                  suppressed      suppressed     consistent
  leanFmt.trailingWhitespace=false REPORTED        suppressed     DISAGREES
```

Full transcript: `evidence/01-two-spellings-disagree.txt`. This was not known when the stack was
written. The roadmap's completion contract — "Rule selection is a projection over canonical facts
and never selects worker, artifact, cache, or scheduling strategy" — reads as a property to
preserve. It is half description and half aspiration: true of `RulePlan`, false of the option, which
selects artifact content, enters the Lake module trace, and (through `moduleConfiguration`'s
`mod.leanOptions`, `Project.lean:229-240`) reaches result-cache identity.

**And one rule's message text is inside every module's compiled bytes.** Editing one space into
FMT001's message changed an unrelated module's `.olean` hash and invalidated its Lake trace.
Transcript: `evidence/02-rule-text-in-every-olean.txt`.

Both defects have one cause, which is what the note is about: the artifact carries *findings*.
Findings are conclusions; the artifact should carry *facts*.

## Commands run

```sh
LEAN_NUM_THREADS=1 lake build                                   # baseline, exit 0
experiments/run-rule-tier-boundary.sh                            # exit 0, both sections
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests                       # exit 0
tests/boundary/run.sh                                            # exit 0
git diff --check                                                 # no output
check_stack.py    docs/projects/ruff-05-rule-engine              # OK: 3 prompts, 0 warnings
write_next.py --check docs/projects/ruff-05-rule-engine          # OK: matches first_unresolved
```

`experiments/run-rule-tier-boundary.sh` is the reproduction for both evidence files. It mutates
`tests/compiler/LocalSyntax.lean` and `LeanFmt/Rules.lean` and restores both on exit, the same way
`tests/compiler/run.sh` does; `git status` is clean after it runs.

Environment: commit `17b517a`, `leanprover/lean4:v4.32.0`, Darwin 25.5.0 arm64. No performance claim
is made here, so no RSS/pressure/swap record applies — the two measurements are a JSON report
comparison and two SHA-256 hashes, neither of which is timing-sensitive.

## What was measured

**1. The two spellings (`evidence/01`).** The fixture carries one FMT001 at normalized bytes
517-519. With `leanFmt.trailingWhitespace=false`, `check` reports it and `format` does not.
`verify-official-facet ... false` passes on the same build, which is the point: it compares the
artifact against `runRules normalized false` (`LeanFmtTest.lean:483-485`), so it tests the artifact
path against itself. The source-only shortcut (`Application.lean:383-389`), which is what a plain
`check` on a current module always takes, calls `runRules normalized true` with the flag as a
literal. Nothing tested it.

**2. The build fanout (`evidence/02`).** Deterministic across two independent runs:

```
LocalSyntax.olean      before = 4cdeb8c87a6b1944c37ecb211dda0f880096411e18b8bf93de379399029d4826
LocalSyntax.olean      after  = 4e707288c7045e5b10cd68e93c3eefd93f196a4d9a49ed9738bc1256a43e8478
```

The trace invalidation is unconditional; the byte change needs a module that has a finding to carry
the message. The whitespace-free fixture gives `ea0a7610...` before and after with the trace still
invalidated, which is why the script mutates the fixture first. Both numbers are in `evidence/02`.

## Decisions, and what changed while making them

**The interface was designed four ways, not two** (note §7): a tier-indexed function table, a
namespace convention, a typeclass/trait registration, and an attribute plus environment extension.
The roadmap named the first three; the fourth was added because it is what Lean's `linterSetsExt`
would suggest to a reader and rejecting it silently would look like an oversight.

**Reading Lean's own source changed the argument, not the answer.** `Lean/Elab/Command.lean:64-70`
defines `Linter`/`ModuleLinter` as a record with a `run` function field and a `name`, registered into
`builtin_initialize lintersRef : IO.Ref (Array Linter)` (`:110-111`) — a function table, not an
attribute, not a typeclass. The comment at `:108-109` says why it is a mutable ref: "Linters should
be loadable as plugins". That is precisely the requirement this roadmap forbids ("no public runtime
plugin ABI"), so the selected design is Lean's shape minus the mutability, and the rejection of
design D rests on Lean having declined the same thing for a reason that does not apply here. Design
A was the expected answer before this reading; it is now the answer with a source behind it.

**The option's diagnosis changed.** The first framing was "the option is a mistake". That is wrong
and the note does not say it: `leanFmt.trailingWhitespace` faithfully copies Lean's per-linter option
pattern (`Lean/Linter/Init.lean:99-107`). What is wrong is that it copies it across a process
boundary — Lean's linters run inside the compiler where the option and the work are in one process,
and lean-fmt's rules do not. §2's table is what that mismatch looks like from outside. This mattered:
it is the difference between "fix the shortcut to read the option" (two deciders that agree today)
and "delete the option" (one decider).

**The tier is a constructor, not a field.** This was the design's reaction to §1's defect. Today
`RuleInfo.input` is a claim no code has to honor, and it drifted to vacuous — `RulePlan.requiresSyntax`
has answered `false` for the product's whole life, which `Application.lean:126-133` already recorded
as the reason a real hazard "could not have been caught". Making the tier the constructor that
carries the implementation means declaring a tier and using it are one act.

**Suppressions raise a run's tier.** Noticed while inventorying `ruff-07`, not planned. A
`-- lean-fmt: ignore[FMT001]` directive must be parsed from lossless comments and never by substring
search, so it is a syntax-tier fact — and it filters source-tier findings. A source-only run with
suppressions enabled therefore needs syntax facts. Recorded in note §5 so `ruff-07` does not discover
it as a surprise.

## Files changed

```
docs/projects/ruff-05-rule-engine/notes/01-rule-facts.md            (new)
docs/projects/ruff-05-rule-engine/results/01-design.md              (new)
docs/projects/ruff-05-rule-engine/evidence/01-two-spellings-disagree.txt   (new)
docs/projects/ruff-05-rule-engine/evidence/02-rule-text-in-every-olean.txt (new)
docs/projects/ruff-05-rule-engine/state/current.md                  (updated)
docs/projects/ruff-05-rule-engine/state/next.md                     (regenerated)
experiments/run-rule-tier-boundary.sh                               (new)
```

## Checks read

`lake build`, `lake exe lean-fmt-tests`, and `tests/boundary/run.sh` all pass and are unaffected —
nothing in `LeanFmt/` changed, so they establish only that the experiment script restored the tree.
That is what they are here to establish. `git diff --check` is silent. The structural checker and
`write_next.py --check` both pass for this stack.

`tests/compiler/run.sh` was **not** run to completion as a gate for this prompt. It is the harness
whose fixture and plugin mutations the experiment borrows, and it rebuilds the plugin repeatedly; the
experiment exercised the same code paths and the same fixture mutation directly, and the tree is
clean afterwards. `RRE-IMPL` changes that harness (note §10.6) and must run it.

## Remaining uncertainty

Carried in note §11 in full. The three that could change `RRE-IMPL`'s shape:

- **The redundant-import rule does not fit the three tiers.** `ruff-09` needs the exact Lake module
  graph, and a rule may not hold project authority. The module-local half (which imports supplied
  constants this module referenced) is `semantic`; the cross-module half is not any of the three.
  This note does not invent a fourth tier for one unwritten rule and leaves the question to
  `RIR-SPEC`, but names it so that stack does not find the model silently excluded it.
- **`source`-tier rules that are about the bytes normalization erased.** `ruff-08` wants BOM and
  mixed-line-ending rules. Every tier indexes the normalized string by design, and a module linter
  "cannot observe the file's bytes at all" (`AGENTS.md`). The information exists at the reader —
  `LosslessSource.normalize` returns the line-ending form — but `SourceFacts` as specified does not
  carry it. Either it gains an explicit raw-shape summary with its own coordinate discipline, or
  those rules are not `source`-tier in this model's sense.
- **Removing the option is a product behavior change**, not a refactor, for any project setting
  `leanFmt.trailingWhitespace=false`. `register_option` makes it public surface. Under the default it
  changes nothing; for `check` users it goes from silently ignored to gone; for `format` users it is
  a rename to `--ignore FMT001`. No deprecation window exists in this repository and this note does
  not invent one.

One thing this prompt deliberately did **not** do: add a characterization test. The behavior in §2 is
a defect, and a test that pinned it would freeze a bug. The invariant it violates — both paths agree
on one file — is note §10.5 and belongs to `RRE-IMPL`, where it can pass.
