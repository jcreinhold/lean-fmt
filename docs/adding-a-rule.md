# Adding a rule

Everything a rule is lives in `LeanFmt/Rules.lean`. A rule is a `RuleInfo` and a `RuleImpl`, and the
`RuleImpl` constructor you pick decides both what your rule reads and what a run has to pay to answer
it. There is no attribute to apply, no typeclass to instantiate, and no registration order to think
about — add an entry to `ruleRegistry` and you are done.

## The shape

```lean
{
  info := {
    code := "FMT003"          -- unique; `lean-fmt rules` and every selector use it
    category := "text"        -- `--select text` expands to every rule in a category
    summary := "..."          -- one line, imperative: what the rule makes true
    fixable := true           -- whether findings carry a `fix?`
    defaultEnabled := true
  }
  impl := .source fun facts => #[...]
}
```

`Rule.tier` derives from `impl`, so there is no tier field to keep in sync and no way to declare one
tier and read another. This is deliberate: the field that used to do this job (`RuleInfo.input`) was a
claim nothing had to honor, and it was wrong for the product's entire life without anything noticing.
The constructor cannot be wrong, because it is what hands you your argument.

## Picking a tier

| `impl` | argument | what a run must obtain |
| --- | --- | --- |
| `.source` | `SourceFacts` | nothing — the file was read to get here |
| `.syntax` | `SyntaxFacts` | the exact frontend's projection: a current `.olean` and its facet, or a frontend invocation |

Pick the cheapest one that can answer your question. `RulePlan.requiredTier` folds `Tier.max` over
whatever the user selected, so a single `.syntax` rule in a selection makes the whole batch pay for
a projection. That is the only thing selection is allowed to decide — it never picks a worker, a
cache identity, or a schedule.

There is no `.semantic` tier yet. When elaboration evidence is needed, it arrives with its facts,
its producer, and its first rule together.

## Coordinates

**Every offset is a byte offset into the normalized source**, which is `raw.crlfToLf`.
`Parser.mkInputContext` normalizes before it assigns any position, so this is the coordinate system
every projection, finding, and digest in the product already shares. `SourceFacts.bytes` is the
normalized source as UTF-8, derived once and shared across rules.

Do not measure against the file's bytes. Reading a file and publishing one are the only operations
that touch raw bytes, and they go through `LosslessSource.normalize`/`denormalize`.

A `fix?` is a byte range and a replacement in those same coordinates. `preparePatch` rejects ranges
that are out of bounds, land inside a UTF-8 scalar, or conflict with another edit — as a unit, so a
bad fix cannot half-apply.

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

So: the compiler projects, and rules decide, outside it, from the projection. If you find yourself
wanting the plugin to know about your rule, that is the boundary talking. `tests/boundary/run.sh`
will stop you, and it is right to.

## Testing it

- `LeanFmtTest.lean`'s `testRules` covers the shipped rules against a fixture with CRLF, trailing
  whitespace, and a missing final newline. Add your cases there.
- If your rule is the first `.syntax`-tier rule the product ships, you have more work than this
  document covers: `Application.renderCanonicalText` and the source-only shortcut in
  `availableAnalysis` both assume every rule is source-tier, and both say so in their docstrings.
  `testEngineTiers` asserts that assumption still holds and will fail when you break it — that
  failure is a to-do list, not a bug.
- `testEngineTiers` and `testMixedSelection` exercise the engine itself through `runRulesOf` and
  `requiredTierOf`, which take a rule array so the tests can register probe rules without shipping
  fake ones. Use that seam for engine behavior; use `ruleRegistry` for your rule's behavior.

## Where the reasoning lives

`docs/projects/ruff-05-rule-engine/notes/01-rule-facts.md` is the design: why a function table rather
than an attribute or a typeclass (§7), why the artifact carries facts and never findings (§6), and
what each tier costs (§5, §8).
