# Adding a rule

Everything a rule is lives in `LeanFmt/Rules.lean`. A rule is a `RuleInfo` and a `RuleImpl`; the `RuleImpl` constructor
you pick decides both what your rule reads and what a run pays to answer it. No attribute to apply, no typeclass to
instantiate, no registration order — add an entry to `ruleRegistry` and you are done.

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
    lifecycle := .stable      -- `.stable`, `.preview`, or `.deprecated`; see below
    previewPath? := none      -- required iff `lifecycle == .preview`; see below
  }
  impl := .source fun facts => #[...]
}
```

## Lifecycle, and why a preview rule must state its way out

`lifecycle` and `defaultEnabled` are separate axes, and all four combinations are meaningful:

| `lifecycle` | `defaultEnabled` | what it means | reachable by |
| --- | --- | --- | --- |
| `.stable` | `true` | the default set | anything |
| `.stable` | `false` | correct, but too expensive or too opinionated for the default path | its code, its category, `all` |
| `.preview` | `false` | not yet judged on corpus evidence | its code, its category, `all` — **only under `--preview`** |
| `.deprecated` | either | on its way out | its code |

`.stable` with `defaultEnabled := false` is not a contradiction. `FMT011` is the live instance: its correctness earned
`.stable`, and its cost — one compiler frontend run per module on a project not built with the plugin, measured at 33×
the default-run budget — kept it off the default path. Do not mark a rule `.preview` because it is expensive; `.preview`
means *unjudged*, not *costly*.

**A `.preview` rule must set `previewPath?` to a nonempty string, and a non-preview rule must leave it `none`.**
`testCatalogInvariants` enforces both directions; the build fails otherwise. Write the condition that would graduate the
rule, concretely enough that someone could test it:

```lean
    previewPath? := some "Graduates when it produces at least 10 audited true positives with zero \
      false positives on a corpus with no `set_option` linter of its own. …"
```

Naming the corpus matters. Ten preview rules ran over 85 mathlib modules and eight never fired — mathlib runs its own
linters for most of what they check. That measured which rules mathlib already enforces, not which rules are correct; a
graduation condition that does not say where the evidence comes from invites the same mistake. The string is shown by
`lean-fmt explain`, in `docs/rules/FMTxxx.md`, and in the JSON, because a path out of preview that lives only in a
result note is a rule nobody will revisit.

`Rule.tier` derives from `impl`, so there is no tier field to keep in sync and no way to declare one tier and read
another. That is deliberate: the field that used to do this (`RuleInfo.input`) was a claim nothing had to honor, and it
stayed wrong for years unnoticed. The constructor cannot be wrong, because it is what gives you your argument.

## Retiring a rule

A retired code moves to `reservedCodes` and stays there forever, so a stale `lean-fmt.toml` or `-- lean-fmt: ignore[…]`
written against it stays *inert* rather than silently binding to a different rule. Never reuse a retired code. The one
exception was the pre-release renumbering, which reused two retired codes because the package had no users; that
argument expired with the first release.

Today `reservedCodes` is empty, so the retirement machinery — `isReservedCode`, `reservedDisposition?`, `explain`'s
`[retired]` branch, the reserved-selector branch in `Config.selectorsValid`, the inert-directive branch in
`Suppression.apply` — has no live instance and **no test coverage**. That is deliberate. The tests that covered it were
deleted rather than repointed at a live code: a test that still passes after its subject is redefined reads as coverage
while testing nothing. A placeholder retired code was considered and rejected for the same reason — it would prove the
placeholder exists, not that the machinery works. Coverage returns when a rule genuinely retires; write the tests then,
against the real code.

## Picking a tier

| `impl` | argument | what a run must obtain |
| --- | --- | --- |
| `.source` | `SourceFacts` | nothing — the file was read to get here |
| `.syntax` | `SyntaxFacts` | the exact frontend's projection: a current `.olean` and its facet, or a frontend invocation |
| `.semantic` | `SemanticFacts` | the projection plus the elaborator's diagnostics |

Pick the cheapest one that answers your question. `RulePlan.requiredTier` folds `Tier.max` over the selection, so one
`.syntax` rule in a selection makes the whole batch pay for a projection. That is the only thing selection may decide —
it never picks a worker, a cache identity, or a schedule.

`SemanticFacts` carries the `SyntaxFacts`, the captured `Diagnostic`s in normalized-source coordinates, and
`occurrences`, the deprecation-occurrence facts. `occurrences` is empty unless the run demanded that capability, and an
empty array means *no fix to offer* — a semantic rule must stay report-only on empty rather than treat it as "nothing
found".

## Coordinates

**Every offset is a byte offset into the normalized source**, `raw.crlfToLf`. `Parser.mkInputContext` normalizes before
assigning any position, so this is the coordinate system every projection, finding, and digest in the product already
shares. `SourceFacts.bytes` is the normalized source as UTF-8, derived once and shared across rules.

Do not measure against the file's bytes. Reading and publishing a file are the only operations that touch raw bytes, and
they go through `LosslessSource.normalize`/`denormalize`.

A `fix?` is a `Fix`: one `applicability` and an array of `edits`, each a byte range and a replacement in those same
coordinates. `preparePatch` rejects ranges that are out of bounds, split a UTF-8 scalar, or conflict with another fix —
as a unit, so a bad fix cannot half-apply, and a conflict names both rules and both finding ranges rather than an array
index.

## Report-only rules

A rule need not carry a fix. `fixable := false` and `impl := .source fun facts => #[…]` with every finding's
`fix? := none` ships a **report-only** rule: it names a problem the formatter cannot correct by reformatting. `FMT001`
(forbidden control byte) and `FMT002` (suspicious bidirectional control) are the shipped examples — both scan bytes in
the `security` category. Report-only is the honest choice when the offending byte sits inside a string literal or a
comment: deleting it changes program data or human-read text, which no byte-level safety argument can call safe (see the
source-rule catalog in `LeanFmt/Rules.lean`). When there is no meaning-preserving edit, emit no fix rather than an
`.unsafe` one nobody should apply.

These two rules also show why a `.source` scan needs no token context: a bare control byte or bidi mark in the command
stream is a parse error, so any such byte in *accepted* source is already inside a string or comment. Acceptance
supplies the context the scan would otherwise need.

## Applicability

Every fix declares how safe it is to apply, following ruff's `Applicability`:

| value | meaning | applied |
| --- | --- | --- |
| `.safe` | meaning-preserving under the rule's stated evidence | by default |
| `.unsafe` | plausibly intended, but the rule cannot prove it preserves behavior/comments/intent | only under `--unsafe-fixes` |
| `.displayOnly` | illustrates the finding; never meant to be applied | never |

"Safe" is a claim under your rule's evidence, tied to its tier — never merely "it reparses". A `.syntax`-tier rewrite
that moves tokens is not safe unless the projection proves meaning is preserved. When in doubt, choose `.unsafe`: a user
opts into it, and a later rule revision can promote it once the evidence exists.

The old trailing-whitespace rule is the warning here, and it argued exactly the way a new rule will want to. It edited
"trivia the lexer cannot see", which sounds safe and is not: a per-line trailing-whitespace scan reaches inside a
multi-line string literal, where those bytes are program data. Line-boundary and final-newline normalization moved into
canonical formatting and the rule was retired. Before calling a fix safe, name the bytes it can reach, not the bytes you
meant it to reach.

Set applicability on the `Fix` you emit; do **not** read configuration to decide it. `extend-safe-fixes` and
`extend-unsafe-fixes` reclassify per rule, resolved in `RulePlan.effectiveApplicability` as a projection over your
emitted value — the same rule that stops a rule from reading its own enablement. No configuration lifts `.displayOnly`:
a rule that declined to make an edit applicable stays declined.

## Ordering

Do not think about it. `runRulesOf` sorts every finding by start, then stop, then code. Your rule's position in
`ruleRegistry` cannot affect output, so you can append without reading the rest of the array.

## What a rule cannot do

A rule is `Facts → Array Finding`. It has no `IO`, no `Environment`, no workspace, no cache, and no project — enforced
by the argument type, not by convention. If your rule seems to need one of those, it is not a rule yet; say so in the
owning stack's notes rather than widening the signature.

Rules must not consult configuration either. `runRules` produces *every* rule's findings and `RulePlan.findings`
projects afterwards. That is what lets one cache entry serve any `--select`, and it is not an optimization to preserve
casually: the last mechanism that let a rule read its own enablement made `check` and `format` report different findings
for the same unchanged file.

## Rules do not run in the compiler

`LeanFmt/CompilerPlugin.lean` does not import `LeanFmt.Rules`, and `lean_lib LeanFmtCompilerPlugin` does not glob it.
Both halves matter — Lake links every module a library globs, imported or not. The plugin is linked into every
compilation of every module of any project that integrates the formatter, so anything reachable from it enters that
project's build graph. While the rules were reachable, editing one rule's message string invalidated every integrated
module's Lake trace and changed the compiled bytes of any module that had a finding.

So the compiler projects, and rules decide outside it, from the projection. If you want the plugin to know about your
rule, you have crossed the boundary; the boundary suite will stop you.

## Testing it

- `lean-fmt-tests`' rule cases cover the formatting rules against a fixture with CRLF, trailing whitespace, and a
  missing final newline. Add your cases there.
- `testSourceSecurityRules` covers the report-only rules: control/bidi bytes inside strings and comments, byte-exact
  ranges (including multibyte marks), and the TAB/LF/DEL boundary. Model a report-only rule's tests on it. `testConfig`
  asserts category selectors (`--select security`) and `testSuppression` that the codes project through suppression like
  any other.
- `testApplicability` covers admission, per-rule reclassification, the display-only limit, and where a conflict came
  from. If your rule ships an `.unsafe` or `.displayOnly` fix, assert its applicability there and add a `--unsafe-fixes`
  case to the modes suite.
- All three tiers ship. The first `.syntax` rules (FMT006–FMT011) and the first `.semantic` ones (FMT012–FMT015) are
  present. `check` reports a rule of any tier, and `fix` applies a syntax fix by re-projecting the canonical text.
  `SemanticResult.tier` and `cacheHitServes` gate the result cache, so a source-only shortcut entry never answers a
  `.syntax` or `.semantic` selection with a false negative. `testEngineTiers` asserts that the registry still holds all
  three.
- `testEngineTiers` and `testMixedSelection` exercise the engine itself through `runRulesOf` and `requiredTierOf`, which
  take a rule array so the tests can register probe rules without shipping fake ones. Test engine behavior through that
  array; test your rule through `ruleRegistry`.

## Where the reasoning lives

`LeanFmt/Rules.lean`'s module docstring is the design: why a function table rather than an attribute or a typeclass
(§7), why the artifact carries facts and never findings (§6), and what each tier costs (§5, §8).
