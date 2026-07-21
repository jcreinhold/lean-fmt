# Adding a rule

Everything a rule is lives in `LeanFmt/Rules.lean`. A rule is a `RuleInfo` and a `RuleImpl`, and the
`RuleImpl` constructor you pick decides both what your rule reads and what a run has to pay to answer
it. There is no attribute to apply, no typeclass to instantiate, and no registration order to think
about — add an entry to `ruleRegistry` and you are done.

## The shape

```lean
{
  info := {
    code := "FMTxxx"          -- unique; `lean-fmt rules` and every selector use it
    category := "text"        -- `--select <category>` expands to every rule that declares it;
                              -- categories are derived from the registry, not a fixed list
    summary := "..."          -- one line, imperative: what the rule makes true
    fixable := true           -- whether findings carry a `fix?`
    defaultEnabled := true
  }
  impl := .source fun facts => #[...]
}
```

`Rule.tier` derives from `impl`, so there is no tier field to keep in sync and no way to declare one
tier and read another. That is on purpose: the field that used to do this job (`RuleInfo.input`) was
a claim nothing had to honor, and it stayed wrong for years unnoticed. The constructor cannot be
wrong, because it is what gives you your argument.

## Picking a tier

| `impl` | argument | what a run must obtain |
| --- | --- | --- |
| `.source` | `SourceFacts` | nothing — the file was read to get here |
| `.syntax` | `SyntaxFacts` | the exact frontend's projection: a current `.olean` and its facet, or a frontend invocation |
| `.semantic` | `SemanticFacts` | the projection plus the elaborator's diagnostics |

Pick the cheapest one that can answer your question. `RulePlan.requiredTier` folds `Tier.max` over
whatever the user selected, so a single `.syntax` rule in a selection makes the whole batch pay for
a projection. That is the only thing selection is allowed to decide — it never picks a worker, a
cache identity, or a schedule.

`SemanticFacts` carries the `SyntaxFacts`, the captured `Diagnostic`s in normalized-source
coordinates, and `occurrences`, the deprecation-occurrence facts of `ruff-11b`. `occurrences` is
empty unless the run demanded that capability, and an empty array means *no fix to offer*, so a
semantic rule must stay report-only on empty rather than treat it as "nothing found".

## Coordinates

**Every offset is a byte offset into the normalized source**, which is `raw.crlfToLf`.
`Parser.mkInputContext` normalizes before it assigns any position, so this is the coordinate system
every projection, finding, and digest in the product already shares. `SourceFacts.bytes` is the
normalized source as UTF-8, derived once and shared across rules.

Do not measure against the file's bytes. Reading a file and publishing one are the only operations
that touch raw bytes, and they go through `LosslessSource.normalize`/`denormalize`.

A `fix?` is a `Fix`: one `applicability` and an array of `edits`, each a byte range and a replacement
in those same coordinates. `preparePatch` rejects ranges that are out of bounds, split a UTF-8 scalar,
or conflict with another fix — as a unit, so a bad fix cannot half-apply, and a conflict names both
rules and both finding ranges rather than an array index.

## Report-only rules

A rule need not carry a fix. `fixable := false` and `impl := .source fun facts => #[…]` with every
finding's `fix? := none` ships a **report-only** rule: it names a problem the formatter cannot correct
by reformatting. `FMT003` (forbidden control byte) and `FMT004` (suspicious bidirectional control) are
the shipped examples — both scan bytes in the `security` category. Report-only is the honest choice
when the offending byte is inside a string literal or a comment: deleting it changes program data or
human-read text, which is not a change a byte-level safety argument can call safe
(`docs/projects/ruff-08-source-rules/notes/01-catalog.md` §3). When there is no meaning-preserving
edit, emit no fix rather than an `.unsafe` one nobody should apply.

These two rules also show why a `.source` scan needs no token context: a bare control byte or bidi
mark in the command stream is a parse error, so any such byte in *accepted* source is already inside a
string or comment. Acceptance supplies the context the scan would otherwise need.

## Applicability

Every fix declares how safe it is to apply, following ruff's `Applicability`:

| value | meaning | applied |
| --- | --- | --- |
| `.safe` | meaning-preserving under the rule's stated evidence | by default |
| `.unsafe` | plausibly intended, but the rule cannot prove it preserves behavior/comments/intent | only under `--unsafe-fixes` |
| `.displayOnly` | illustrates the finding; never meant to be applied | never |

"Safe" is a claim under your rule's evidence and is tied to its tier — never merely "it reparses". A
`.syntax`-tier rewrite that moves tokens is not safe unless the projection proves the meaning is
preserved. When in doubt, choose `.unsafe`: a user opts into it, and a later rule revision can promote
it once the evidence exists.

The retired FMT001 is the warning here, and it argued exactly the way a new rule will want to. It
edited "trivia the lexer cannot see", which sounds safe and is not: a per-line trailing-whitespace
scan reaches inside a multi-line string literal, where those bytes are program data
(`ruff-11c evidence/01-fusion-and-subsumption.md`, probe 4/6). Line-boundary and final-newline
normalization moved into canonical formatting and both codes are retired and reserved — `check` says
so if you select one. Before calling a fix safe, name the bytes it can reach, not the bytes you meant
it to reach.

Set applicability on the `Fix` you emit; do **not** read configuration to decide it. `extend-safe-fixes`
and `extend-unsafe-fixes` reclassify per rule, but that is resolved in `RulePlan.effectiveApplicability`
as a projection over your emitted value — the same rule that stops a rule from reading its own
enablement. No configuration lifts `.displayOnly`: a rule that declined to make an edit applicable
stays declined.

## Ordering

Do not think about it. `runRulesOf` sorts every finding by start, then stop, then code. Your rule's
position in `ruleRegistry` cannot affect output, which is why you can append without reading the rest
of the array.

## What a rule cannot do

A rule is `Facts → Array Finding`. It has no `IO`, no `Environment`, no workspace, no cache, and no
project. This is enforced by the argument type rather than by convention. If your rule seems to need
one of those, it is not a rule yet — say so in the owning stack's notes rather than widening the
signature.

Rules must not consult configuration either. `runRules` produces *every* rule's findings and
`RulePlan.findings` projects afterwards. That is what lets one cache entry serve any `--select`, and
it is not an optimization to preserve casually: the last mechanism that let a rule read its own
enablement made `check` and `format` report different findings for the same unchanged file.

## Rules do not run in the compiler

`LeanFmt/CompilerPlugin.lean` does not import `LeanFmt.Rules`, and `lean_lib LeanFmtCompilerPlugin`
does not glob it. Both halves matter — Lake links every module a library globs whether or not
anything imports it. The plugin is linked into every compilation of every module of any project that
integrates the formatter, so anything reachable from it is in that project's build graph. While the
rules were reachable, editing one rule's message string invalidated every integrated module's Lake
trace and changed the compiled bytes of any module that had a finding.

So the compiler projects, and rules decide outside it, from the projection. If you want the plugin to
know about your rule, you have crossed the boundary. `tests/boundary/run.sh` will stop you.

## Testing it

- `LeanFmtTest.lean`'s `testRules` covers the formatting rules against a fixture with CRLF, trailing
  whitespace, and a missing final newline. Add your cases there.
- `testSourceSecurityRules` covers the report-only rules: control/bidi bytes inside strings and
  comments, byte-exact ranges (including multibyte marks), and the TAB/LF/DEL boundary. Model a
  report-only rule's tests on it. `testConfig` asserts category selectors (`--select security`) and
  `testSuppression` that the codes project through suppression like any other.
- `testApplicability` covers admission, per-rule reclassification, the display-only limit, and where a
  conflict came from. If your rule ships an `.unsafe` or `.displayOnly` fix, assert its applicability there and
  add a `--unsafe-fixes` case to `tests/modes/run.sh`.
- All three tiers ship: `ruff-10` added the first `.syntax` rules (FMT008–FMT013) and `ruff-11` the
  first `.semantic` ones (FMT014–FMT017). `check` reports a rule of any tier, and `fix` applies a
  syntax fix by re-projecting the canonical text — the model `ruff-06`'s RFX-SPEC froze and
  `ruff-10b-syntax-fix-composition` finished. `SemanticResult.tier` and `cacheHitServes` gate the
  result cache, so a source-only shortcut entry never answers a `.syntax` or `.semantic` selection
  with a false negative. `testEngineTiers` asserts that the registry still holds all three.
- `testEngineTiers` and `testMixedSelection` exercise the engine itself through `runRulesOf` and
  `requiredTierOf`, which take a rule array so the tests can register probe rules without shipping
  fake ones. Test engine behavior through that array; test your rule through `ruleRegistry`.

## Where the reasoning lives

`docs/projects/ruff-05-rule-engine/notes/01-rule-facts.md` is the design: why a function table rather
than an attribute or a typeclass (§7), why the artifact carries facts and never findings (§6), and
what each tier costs (§5, §8).
