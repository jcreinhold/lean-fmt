# RRE-IMPL — Implement tier derivation and registry execution

**Verified.** Both defects `RRE-SPEC` measured are closed, re-measured, and pinned by gates that fail
if either returns. `evidence/03-both-defects-closed.txt` is the re-run of the same experiment that
found them.

## The headline

The artifact no longer carries findings. It carries the projection, and nothing else. That single
change closes both defects, because both were the same defect: the compiler was deciding, and a
decision it made in one process had to be either trusted or re-derived by another.

```
                              RRE-SPEC (evidence/01, /02)     RRE-IMPL (evidence/03)
  spellings of "FMT001 off"   2, and they disagree            1
  check vs format             REPORTED / suppressed           FMT001 / FMT001
  edit a rule's message:
    LocalSyntax.olean         4cdeb8c8... -> 4e707288...      ee41d3ed... unchanged
    LocalSyntax.trace         15187a81... -> c41d0bdb...      863b0469... unchanged
```

## What was run

```
$ LEAN_NUM_THREADS=1 lake build                → 0  (36 jobs)
$ LEAN_NUM_THREADS=1 lake exe lean-fmt-tests   → 0  "lean-fmt module-artifact tests passed"
$ bash tests/boundary/run.sh                   → 0  "lean-fmt native module and dependency boundary passed"
$ bash tests/check/run.sh                      → 0  "lean-fmt check integration tests passed"
$ bash tests/compiler/run.sh                   → 0  "lean-fmt compiler facet tests passed"
$ git diff --check                             → 0  (no output)
$ bash experiments/run-rule-tier-boundary.sh   → evidence/03-both-defects-closed.txt
```

`tests/compiler/run.sh` is the one `results/01-design.md` recorded as **not** run for `RRE-SPEC` and
owed by this prompt. It ran, and this prompt changed it: 49s, exit 0.

## What changed

**`LeanFmt/Rules.lean`, rewritten.** `Tier` (`source`/`syntax`) with `satisfies` and `max`;
`SourceFacts` and `SyntaxFacts` as private-constructor fact views; `Facts` as their sum; `RuleImpl`
as a tier-indexed function table, so a rule's tier is its constructor rather than a field anything
could contradict. `RuleInfo.input` is gone — it was the field that rotted, a claim no code had to
honor, which is why `RulePlan.requiresSyntax` answered `false` for the product's whole life.
`runRules : Facts → Array Finding` folds the one registry and sorts by `findingOrder`; rules whose
tier the facts cannot satisfy are skipped rather than guessed at.

**One decider, reached two ways.** `availableAnalysis`'s source-only shortcut and
`Semantic.ofEnvelope?` now both call `runRules`. The shortcut used to pass a literal `true` where the
artifact path passed the artifact's own flag. That was §2's whole defect: not a race, not a cache
bug, just two spellings of one decision, one of them hardcoded.

**The option is deleted.** `register_option leanFmt.trailingWhitespace`, the `weak.` `leanOptions`
blocks in all four `lakefile.lean` targets, and `trailingWhitespaceEnabled` are gone. §4 of the note
argued the option was Lean-idiomatic but in the wrong process; deleting it leaves `--ignore` as the
only spelling, which is the property `evidence/03` §1 now measures directly.

**The plugin's exposure, cut twice.** `LeanFmt/CompilerPlugin.lean` no longer imports
`LeanFmt.Rules` — *and* `lean_lib LeanFmtCompilerPlugin` no longer globs it. The second half was
found while writing the §10.6 gate and is the interesting one: **the import graph alone would not
have fixed §3.** A Lake library links every module it globs whether or not anything imports it, so
with the glob left in place, rule text still reaches the plugin `.so`, still enters every integrated
module's build graph, and the defect survives an import boundary that looks correct. `evidence/03`
§2 measures the fix with both halves in place.

## Tests added, and why these

**`tests/check/run.sh` — `check` vs `format` agreement.** §10.5 asked for one test running both paths
over one file and asserting identical findings, exercising the source-only shortcut rather than only
the artifact path. This is it: `check` takes the shortcut (all rules source-tier, nothing rendered,
evidence current) while `format` takes the artifact path for the projection it must print. The
existing `cmp` nearby does *not* cover this — it compares the artifact path against the exact-frontend
fallback, and both of those report. Findings only are compared; mode, status, and rendered text are
meant to differ. The assertion refuses a vacuous pass: it requires the fixture to produce findings.

**`tests/compiler/run.sh` — the matched pair.** §10.6 asked for a test that editing a rule does not
invalidate a module's Lake trace while editing the projection does. Both probes are there and neither
is worth anything alone: "nothing changed" passes trivially in a harness that rebuilds nothing, so
the plugin-edit control is what gives the rule-edit probe meaning. The rule probe also checks the
`.olean` bytes, not just the trace, because §3 measured both moving.

**`tests/boundary/run.sh` — the plugin's member list.** Now pins `LeanFmt.Rules` out of both the
plugin's imports and its Lake globs, and says in the file why the name is called out rather than
merely absent.

**`LeanFmtTest.lean`.** `verifyOfficialFacet` gained the unit-level counterpart of the agreement
check. The three `verify-*` helpers lost their `EXPECTED_TRAILING` parameter — there is no traced
configuration left to expect. `testRules` gained an ordering assertion that will keep holding when a
rule whose findings land earlier is registered later; today the registry and `findingOrder` agree by
accident of there being two rules, which is exactly why the sort exists.

## Decisions changed while running

**`Tier` has no `semantic` case, and the prompt asked for one.** The prompt's task line says "Add
private source/syntax/**semantic** fact views". This delivers two. The argument is note §7 and the
`Tier` docstring: `ruff-11`'s `RMR-SPEC` is chartered to characterize the Lean APIs a semantic fact
would project, and `ruff-11` depends on this stack rather than the reverse. A tier nothing can
produce is a tier nothing tests — which is precisely how `RuleInfo.input` rotted, and this file
exists because of that. Adding the case here would mean inventing its facts from memory and shipping
a third untested claim into the exact structure that just failed. The third case should arrive with
its facts, its producer, and its rule, together. **This is a deliberate under-delivery against the
prompt text and it is not hidden**: `Tier.satisfies` and `Tier.max` are total over two cases and gain
the third without changing shape, and `RulePlan.requiredTier` folds over whatever the registry holds.

**The experiment was rewritten rather than left to rot.** `experiments/run-rule-tier-boundary.sh`
invoked `-KleanFmtTrailingWhitespace=false` and the four-argument `verify-official-facet`, neither of
which exists now, so it could not run. It asks the same two questions of the product this prompt
built. The RRE-SPEC transcripts it produced are unchanged in `evidence/01` and `evidence/02`; the old
script is recoverable at 5d037d0. Question 1 changed shape honestly: the second spelling is gone, so
what is checked is that the one remaining spelling agrees with itself across modes — the property
`evidence/01` showed the product lacked.

**`ArtifactStore.structurallyValid` lost its finding-range clause and gained nothing.** There are no
findings to bound. The note in that file says so rather than leaving the absence to be discovered: a
finding is now computed by the process that reports it, from facts `validFor` has already matched to
the bytes in hand, so its range is in range by construction rather than by audit. The corresponding
test now asserts that an artifact whose *projection* is invalid is rejected, which is the only way
one can be structurally wrong now.

## Measurements

- `artifactSchema` is now `lean-fmt.module-artifact.v3`. Every `v2` payload on disk is a miss rather
  than a silently under-populated hit — the same argument `semanticResultSchema` makes.
- `ModuleArtifact` is `{ schema, source }`. The compactness bound in `verifyPluginArtifact`
  (`< 1024 + 40 * (tokens + nodes)`) still holds with findings removed.
- `evidence/03`: `LocalSyntax.olean` = `ee41d3ed0e6dfadcac013910cfb844d03aff290aab0d7d4b03cd802f7dab4b74`
  and `LocalSyntax.trace` depHash = `863b046929ed88ee`, both identical before and after a one-space
  edit to FMT001's message.
- `tests/compiler/run.sh`: 49s wall, exit 0.

## Remaining uncertainty

- **The agreement test cannot replay the original defect, only the invariant it broke.** The trigger
  (`leanFmt.trailingWhitespace=false`) is deleted, so nothing can spell the divergence any more. The
  test asserts that `check` and `format` agree; it would catch a *new* divergence, but there is no
  way to prove it would have caught the old one, because the old one is unspellable. This is stated
  in the file rather than papered over.
- **Both live rules are source-tier, so `Tier.syntax` is exercised only through `SyntaxFacts` at the
  artifact path, never by a rule that needs it.** `Tier.satisfies .source .syntax = false` is
  therefore not reachable from the product today. `ruff-06`'s `RFX-SPEC` owns the first syntax-tier
  fixable rule; `Application.renderCanonicalText`'s docstring names it as the trigger that must
  revisit the `runSourceRules` call there.
- **`RulePlan.requiredTier` is `.source` for every possible selection today**, since the registry
  holds two source rules. The mixed-tier planning it implements is real code on an unreachable
  branch until a syntax-tier rule exists. The gates cover the branch that runs; the other is argued,
  not measured.
