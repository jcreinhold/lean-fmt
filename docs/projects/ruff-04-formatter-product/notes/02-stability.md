# The stable formatter policy, and what changing it costs

`notes/01-policy.md` decided the policy. This publishes it as the thing users and future prompts are
held to, and records what it takes to change. `RFP-FINAL` verified it on foreign Lean; the figures
here are `evidence/06-frozen-sample.txt` and `evidence/07-command-matrix.txt`.

## 1. The style is not configurable, and that is the stable part

There is no `[format]` section, no `line-width`, no `indent-*`, no line-ending knob. This is not a
deferral, and it is not "we'll add it later if asked". `RFP-SPEC` proved the knobs cannot change a
byte: `Doc.go` reads the margin at exactly one place — the `.group`/`.brk` fit test
(`Doc.lean:219-229`) — and `LeanFmt/Printer.lean` emits only `Doc.text`, `Doc.hard`, and
`Doc.verbatim`. No `group` is ever built, so `fits` is never called, so the margin is never read.

`RFP-FINAL` checked that on Lean nobody wrote for it. The printer harness formats the frozen sample at
width 80; the product formats it at 100. On the 12 modules the printer actually changes, the outputs
are **byte-identical, 12 of 12**. A knob at either value would have moved nothing.

The number the product passes internally is `canonicalWidth := 100` (`Application.lean:315`). It is a
constant, not a default, because a default implies an alternative.

**What reverses this.** The first `group` in `Printer.lean`. At that moment the margin becomes
observable, and `line-width` must arrive **in the same commit as its cache-identity component** — not
in a follow-up. Today's `CacheIdentity` (`Cache.lean:29-37`) is *accidentally* correct: it keys
findings only, and style cannot change a finding. A `group` breaks that silently, leaving every
existing cache entry consistent under an identity that never mentioned the width that produced it.
Consistent and wrong is the failure no test catches.

## 2. Formatting is not a rule, and cannot be selected

`--select`, `--ignore`, and `per-file-ignores` reach rules. They do not reach layout, because layout
is not a rule — it has no code, no category, and no fix. `check` reports selected rules and never
moves; `format`, `diff`, and `fix` render canonical layout and do not consult selection to decide
whether to.

This is why `tests/check/Layout.lean` is `check`-clean at exit 0 and `format`-`would-format` at exit 1
on the same bytes, with `findings=0` in both. That pair is not an inconsistency to be reconciled later;
it is the interface.

## 3. Exit codes are two rules

| command | exits 1 when |
| --- | --- |
| `check` | there are findings. Layout cannot make it exit 1. |
| `format`, `diff` | the file would change — a fix, layout, or both. |
| `fix` | it failed. Succeeding is 0 whatever it had to write. |

`2` is a usage or configuration error (an unknown config key, for instance). `3` is not lean-fmt's;
it is Lake's `noBuildCode` escaping a `runBuild` that was not guarded by `checkNoBuild`, and if a user
ever sees it, that is a bug in this repository, not a status to interpret
(`evidence/03-nobuild-exits-the-process.txt`).

## 4. Migration: there is no alias, because `check` is the migration

`format` gained behavior. A lint-clean but non-canonically laid-out file goes from exit 0 to exit 1,
which breaks a CI gate on unchanged code. That is real, and it is the intended consequence of the
command doing its job.

There is no old name to alias. `format` was widened, not renamed, and a `format-legacy` would preserve
semantics nobody chose — today's behavior was an accident of the printer never being wired in, not a
decision anyone made.

**The migration is a command that already exists.** Anyone whose `format` gate meant *"does anything
need fixing"* wants `check`:

- it reports selected rules and does not move, so this change cannot affect it;
- it is stricter, not weaker — it exits 1 on a finding that has no fix, where `format` exits 1 only on
  a change it can make.

**How much moves in practice.** On the frozen mathlib sample, `format` changes **12 of 62 modules**
(19%) with `findings=0` across all of them — so on real foreign Lean this is entirely layout, and about
one file in five. That is the number to quote to someone deciding whether to adopt `format` in CI, and
it is measured, not estimated (`evidence/06-frozen-sample.txt`).

## 5. What a style change costs after this stack

The prompt's stop rule is "any style change after this stack requires preview or an explicit
compatibility decision". Concretely, a change to what the printer emits must carry:

1. **A preview.** The frozen sample re-run, reporting how many of the 62 move and how. `12` is the
   current baseline; a change that moves it is changing real files.
2. **Idempotence, re-measured.** `format(format(x)) = format(x)` is currently 12 of 12 at width 100 on
   the modules that move. A layout that oscillates passes every golden and fails this.
3. **Information preservation, re-measured.** The printer harness's token-and-comment comparison. This
   is the check that catches a layout which *accepts* wrongly — a dropped comment or a swallowed token
   shows up here and nowhere else. It is how RLF-COMMANDS found the header layout deleting a blank line
   between mathlib's `public import`s and its plain `import`s.
4. **The cache-identity question, answered explicitly.** If the change makes any input to the layout
   observable to a user, that input joins `CacheIdentity` in the same commit. If it does not, say why.

Goldens alone are not sufficient for any of the four, which is why none of them is a golden.

## 6. Remaining uncertainty

- **The sample is a frozen list of paths, not frozen content.** It is named `mathlib-v4.32.0-sample.txt`
  and pinned by `RLS-FINAL`, but it was read here from a `master-2026-07-14` checkout. All 62 paths
  resolve, so the sample is intact and the measurements are real; they are just measurements of *that*
  commit. A genuinely frozen sample would pin content, and nothing here does.
- **19% is 62 modules, not 8,795.** Full mathlib is forbidden in this stack and was not run. Whether
  12/62 generalizes is unmeasured, and the sample was selected by `RLS-FINAL` for reasons this stack
  did not re-audit.
- **`format` has never been observed rejecting its own output.** The validator refuses to write text
  that fails to elaborate, and the test for that path forces the rejection with a stub validator
  (`LEAN_FMT_TEST_VALIDATOR`) because the printer has never actually produced text that fails. That the
  path works is tested; that it is *needed* is not evidence anyone has.
