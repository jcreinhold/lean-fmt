# Rule facts, tiers, and the contribution interface

`RRE-SPEC`. This freezes what a rule *is* in `lean-fmt`: what it may read, who produces what it
reads, how it is contributed, and which of its properties may touch a cache identity. It changes no
product behavior. `RRE-IMPL` does that, and this note is what it must implement against.

Two things are measured here rather than assumed, and both are defects in the live product. They are
what the design has to answer for, so they come first.

## 1. The engine today

`LeanFmt/Rules.lean` is 111 lines and holds two independent things that never meet:

- `ruleRegistry : Array RuleInfo` (`Rules.lean:22-39`) — pure metadata. `code`, `category`,
  `summary`, `fixable`, `defaultEnabled`, and `input : RuleInput` where `RuleInput` is
  `.source | .syntax` (`Rules.lean:8-11`).
- `runRules (normalized : String) (checkTrailingWhitespace := true)` (`Rules.lean:93-95`) — the
  implementations, hard-coded: `trailingWhitespace bytes ++ finalNewline bytes`.

**Nothing connects them.** `runRules` never reads `ruleRegistry`; `ruleRegistry` never names a
function. A registry entry's `input` field is a *claim about* an implementation it cannot reach, and
the only consumer of that claim is `RulePlan.requiresSyntax` (`Config.lean:199-200`), which asks
whether any selected rule has `input == .syntax`. Both entries say `.source`, so it has answered
`false` for the product's whole life. `RFP-IMPL` found this the hard way and wrote it down
(`Application.lean:126-133`): a stale-module hazard in `officialArtifacts` "could not have been
caught... no product path ever called this with a stale module", because the field that would have
routed a caller there was decorative.

That is the shape of the problem. `input` is a label, not a constraint. A label that no code has to
honor is one that drifts, and this one drifted to vacuous.

Selection is separately in good order. `RulePlan` (`Config.lean:24-27`) expands `all`/`text`/code
selectors, and `RulePlan.findings` (`Config.lean:192-195`) filters findings *after* they exist.
`CanonicalText`'s docstring (`Semantic.lean:18-19`) states the property this buys: "Both are
selection-independent — `runRules` produces every rule's findings and `RulePlan.findings` projects
afterwards — so one cache entry still serves any `--select`." That is exactly the roadmap's
completion contract, and it is already true.

It is true of `--select`. It is not true of the other way to turn a rule off.

## 2. Defect: two spellings of one intent, and they disagree

`evidence/01-two-spellings-disagree.txt`. There are two ways to say "do not report FMT001":

| | `check` | `format` |
| --- | --- | --- |
| `--ignore FMT001` | suppressed | suppressed |
| `leanFmt.trailingWhitespace=false` | **reported** | suppressed |

`--ignore` is a `RulePlan` projection and lands identically on both paths. The option is a rule
selector routed through artifact construction: `CompilerPlugin.lean:25` reads it, passes it to
`ModuleArtifact.ofParsedModule`, and it is stored in the artifact (`ArtifactModel.lean:38`) and
re-read on the consumer side (`Application.lean:327`).

`check` never reads the artifact. `availableAnalysis` (`Application.lean:383-389`) takes a
source-only shortcut when no selected rule needs syntax, the mode renders no canonical text, and the
module's evidence is `.current` — and that shortcut calls `runRules normalized true`. The flag is
the literal `true`. So a project that disables the rule in its build gets it reported by `check`
anyway, and not by `format`. One rule, two deciders, no agreement.

Nothing caught it. `verify-official-facet` (`LeanFmtTest.lean:483-485`) compares the artifact
against `runRules normalized expectedTrailingWhitespace` — it tests the artifact path against
itself. The shortcut, which is the path every plain `check` takes, had no test that could see the
option at all.

## 3. Defect: one rule's message text is inside every module's compiled bytes

`evidence/02-rule-text-in-every-olean.txt`. `LeanFmt/CompilerPlugin.lean:4` is
`import all LeanFmt.Rules`, and `lakefile.lean:114,121,132` list the plugin as a Lake dependency of
every fixture module. So the rules are linked into the plugin, and the plugin is a dependency of
every module in any project that integrates the formatter.

Editing one space into FMT001's message string — no verdict change, no range change, no projection
change — did this:

```
LocalSyntax.olean      before = 4cdeb8c8...  after = 4e707288...   BYTES CHANGED
LocalSyntax.trace hash before = 15187a81...  after = c41d0bdb...   INVALIDATED
```

Two distinct costs. The **trace** invalidation is unconditional: touch any rule, re-elaborate every
module in the target project. The **byte** change needs a module that actually has a finding to
carry the prose. `tests/compiler/run.sh:102-123` already asserts the invalidation and asserts it as
a *feature* — "a real plugin binary change must invalidate the module job" — which is right for a
projection change and wrong for a rule-message change. Today they are the same event, so the test
cannot tell them apart.

`ruff-08` through `ruff-11` add four rule families. Under this arrangement, every edit to any of
them re-elaborates the target project. The frozen sample is 62 modules; mathlib is roughly 6000.

## 4. Diagnosis: the option is Lean-idiomatic, in the wrong process

The option is not an arbitrary mistake, and the design must say why it is wrong rather than just
that it is. Lean gates each of its own linters with an option — `linter.all`, `linter.extra`, and
per-linter options organized into sets (`Lean/Linter/Init.lean:99-107,20-70`). `leanFmt.trailingWhitespace`
copies that pattern faithfully.

It copies it across a process boundary where it stops meaning anything. Lean's linters *run inside
the compiler*: the option and the work it gates are in one process, so the option reaches the work
by construction. `lean-fmt`'s rules run outside the compiler, against a projection, in a later
process — and on the common path (`check` on a current module) the compiler is not involved at all.
An option set in the compiler cannot select work in a process the compiler never starts. That is not
a bug in the plumbing; it is what the two-process architecture means, and §2's table is what it
looks like from outside.

So: **rule enablement is not a compiler option.** It is `RulePlan`, which already works, already
lands on every path, and already keeps one cache entry serving every selection.

## 5. The tier model

A rule declares what it needs to decide. Three tiers, and the roadmap names them: raw source,
lossless syntax, semantic/elaboration evidence.

| Tier | Facts | Who can produce them | Cost to obtain |
| --- | --- | --- | --- |
| `source` | the normalized source string | anyone holding the bytes | already paid — the file was read |
| `syntax` | the `LosslessSource` projection | the exact frontend only (plugin, or `analyzeExact`) | a current `.olean` + facet, or a frontend run |
| `semantic` | immutable elaboration evidence | the exact frontend only | as above, richer payload |

"Normalized" is load-bearing and already settled: every compiler-produced offset indexes
`raw.crlfToLf` because `Parser.mkInputContext` normalizes before assigning any position
(`AGENTS.md`, `Rules.lean:89-92`). All three tiers share that one coordinate system. A rule never
sees raw bytes.

**The tier of a run** is the maximum over: every selected rule's tier; `syntax` if the mode renders
canonical text (`RunMode.rendersCanonical`, `Application.lean:40`); and — when `ruff-07` lands —
`syntax` if source suppressions are enabled, because `-- lean-fmt: ignore[CODE]` must be parsed from
lossless comments and never by substring search (`ruff-07-suppressions/roadmap.md`). That last one
is a real consequence worth stating now: **suppressions raise the tier of an otherwise source-only
run**, because a source-tier finding can be suppressed by a syntax-tier fact.

That maximum is the whole of "derive the cheapest exact capability":

- `source` → no artifact, no frontend. Read bytes, run rules.
- `syntax` → the official facet when the module is current, the exact frontend otherwise.
- `semantic` → the same carriers, a larger payload.

`RulePlan.requiresSyntax` becomes `RulePlan.requiredTier` and acquires, for the first time, a value
that is not constant.

## 6. Fact ownership: the artifact carries facts, never findings

This is the load-bearing decision.

Today `ModuleArtifact` carries `findings : Array Finding` (`ArtifactModel.lean:40`) computed inside
the compiler. **It should carry none.** The artifact carries facts a reader cannot recompute — the
projection, and later the semantic evidence. Findings are computed by whoever holds the facts, on
the consumer side, always, at every tier.

The reasons compound:

1. **A source-tier rule needs nothing the consumer lacks.** The consumer read the file. Shipping
   FMT001's verdict through an `.olean` so the consumer can deserialize a conclusion it could reach
   from bytes in hand is strictly more work than computing it — and on the source-only path the
   consumer computes it anyway (`Application.lean:389`). The artifact copy is redundant in the
   common case and wrong in the rare one.
2. **It removes §3's cost by removing its cause.** With rules out of the plugin's import closure,
   the plugin depends on the projection and nothing else. Editing a rule then invalidates nothing:
   no trace, no `.olean`, no target-project rebuild. Editing the *projection* still invalidates
   everything, which is correct and is what `tests/compiler/run.sh:102-123` should be pinned to.
3. **It removes §2's disagreement by construction.** Two deciders disagreed. Delete one and there is
   nothing left to disagree with. This is not the same as fixing the shortcut to read the option —
   that would leave two deciders that happen to agree today.
4. **The artifact stops depending on the rule set.** Adding a rule in `ruff-08`..`ruff-11` currently
   changes what every artifact contains. Facts do not change when rules change, so a rule addition
   becomes a change to `lean-fmt` alone — which the result cache already covers through its
   `formatter` digest (`Cache.lean:33`).

The objection is on the record and must be answered, because it is the current design's stated
defense. `SemanticAnalysis.ofEnvelope?` (`Semantic.lean:86-89`) says: "The artifact's own findings
are canonical here — recomputing them on this side would be a second opinion about a module this
process never elaborated, and could disagree with the artifact under different options."

The clause "under different options" is doing all the work, and it is circular: findings can
disagree under different options **only because the option exists**. Remove it, and a source-tier
rule is a pure total function of the normalized string. `artifact.source.validFor raw`
(`ArtifactStore.lean:27-31`) already proves the artifact describes exactly these bytes. Same input,
same pure function, same output — there is no second opinion available. And the empirical answer is
sharper than the argument: carrying findings in the artifact did not prevent disagreement, it
*caused* the one measured in §2.

The same reasoning extends up. A syntax-tier rule runs on the consumer side from the projection the
artifact carries; the artifact need not carry its findings either. A semantic-tier rule runs from
semantic facts the artifact carries. In every case: **the plugin projects, it does not lint.**

What this deletes, for `RRE-IMPL` to carry out:

- `ModuleArtifact.findings` and `ModuleArtifact.trailingWhitespace` (`ArtifactModel.lean:38,40`)
- `register_option leanFmt.trailingWhitespace` (`CompilerPlugin.lean:11-14`)
- `trailingWhitespaceEnabled` and the three `leanOptions` blocks (`lakefile.lean:74-75,115-116,122-123,133-134`)
- `validFinding` from `structurallyValid` (`ArtifactStore.lean:23`) — no findings left to validate
- `import all LeanFmt.Rules` from `CompilerPlugin.lean:4`
- the `checkTrailingWhitespace` parameter threaded through `runRules`, `ofParsedModule`,
  `analyzeExact`, and `renderCanonicalText`

The artifact schema is `lean-fmt.module-artifact.v2` and must go to `v3`: a `v2` payload decoded as
`v3` would read as an artifact whose facts are intact and whose findings vanished, which is
indistinguishable from a clean module. Schema mismatch must make it a miss, exactly as
`artifactSchema`'s docstring already requires (`ArtifactModel.lean:43-45`).

## 7. The contribution interface, designed four ways

The roadmap asks for the shallowest interface that lets a first-party rule declare metadata, its
tier, its diagnostics, and its fixes, without receiving application, project, or cache authority.
Compiled first-party contribution only: the roadmap forbids a public runtime plugin ABI.

**Lean already answered the shape of this question**, and the answer is worth reading before
inventing one. `Lean/Elab/Command.lean:64-70`:

```lean
structure Linter where
  run : Syntax → CommandElabM Unit
  name : Name := by exact decl_name%

structure ModuleLinter where
  run : Array Syntax → CommandElabM Unit
  name : Name := by exact decl_name%
```

registered into `builtin_initialize lintersRef : IO.Ref (Array Linter)` (`:110-111`) with the
comment (`:108-109`): "Linters should be loadable as plugins, so store in a global IO ref instead of
an attribute managed by the environment (which only contains `import`ed objects)."

That is a **function table**: a record with a function field and a name, in an array. Not a
typeclass, not an attribute, not a namespace convention. And its one concession to dynamism — the
mutable ref — is bought by a requirement this roadmap explicitly does not have.

### A — tier-indexed function table (selected)

```lean
/-- What a rule needs in order to decide. The constructor *is* the tier declaration: the tier
determines the argument type, so a rule cannot claim one tier and read another. -/
private inductive RuleImpl where
  | source   (run : SourceFacts   → Array Finding)
  | «syntax» (run : SyntaxFacts   → Array Finding)
  | semantic (run : SemanticFacts → Array Finding)

private structure Rule where
  info : RuleInfo        -- code, category, summary, fixable, defaultEnabled
  impl : RuleImpl

def Rule.tier : Rule → Tier
def ruleRegistry : Array Rule
```

The point of the sum is §1's defect. Today `input` is a field a rule *sets* and no code checks;
here the tier is the constructor that carries the implementation, so declaring a tier and using it
are one act and cannot drift. `Rule.tier` is derived, and `lean-fmt rules --json` derives `input`
from it rather than reading a field that might lie.

Against the prompt's criteria: a caller knows `Tier` and `Array Finding` and nothing else. `run` is
pure and total — no `IO`, no exceptions, no error surface, and no way to reach a workspace, a cache,
or an `Environment`; the roadmap's "no application/project/cache authority" is enforced by the
argument type rather than by review. The registry is a static array, so ordering is positional and
deterministic and `lean-fmt rules` cannot depend on import order. Nothing in the registry enters a
cache identity (§8). Cost is one array traversal, filter by tier, map.

This is Lean's `Linter` shape, minus the mutable ref lean-fmt does not need, plus a tier index Lean
does not need because Lean's linters all run in one place.

The deliberate divergence: Lean's `run` returns `CommandElabM Unit` and lean-fmt's returns
`Array Finding`. Lean's linters run inside the compiler and legitimately need that authority.
lean-fmt's rules run outside on immutable projections, and `SemanticFacts` must never leak a mutable
`Environment` — a `CommandElabM`-shaped signature would hand every rule exactly what this stack's
stop rule forbids.

### B — namespace convention

One namespace per rule (`LeanFmt.Rules.FMT001`) exposing `info` and `run`. Lean cannot enumerate a
namespace's declarations without meta-programming, so gathering still needs a hand-written array of
references — design A, plus a layer, minus the type-level tier link. It hides no invariant A does
not. Rejected: strictly more indirection for strictly nothing.

### C — typeclass / trait registration

`class Rule (α : Type) where info : RuleInfo; run : Facts α → Array Finding`. Two independent
failures. Instance resolution answers "is there an instance for this type", not "enumerate every
instance" — so gathering needs an attribute and an environment extension anyway, making C equal to D
plus a class. And tier polymorphism makes the registry heterogeneous, so the entries need existential
packing, which reintroduces A's sum type underneath the class. Rejected: it is A and D stacked, and
it is the "speculative trait hierarchy" the roadmap's completion contract names.

### D — attribute plus environment extension

The `@[builtin_linter]`-shaped design; the one a reader might expect from Lean's `linterSetsExt`
(`Lean/Linter/Init.lean:55-70`). Rejected on four counts. It makes the registry dynamic, so rule
order — and therefore `lean-fmt rules` output and finding order before sorting — depends on import
order, against the roadmap's determinism requirement. It is the seed of a public runtime plugin ABI,
which the roadmap forbids. It buys dynamism for a set of rules that is compiled, first-party, and
known at build time. And it puts an environment extension in the plugin's import closure, which is
§3's cost re-entering by another door. Note that Lean itself declined the attribute for linters and
used a ref, for a reason (plugin loadability) that does not apply here.

**A is selected.**

## 8. Cache boundaries

Three identities, and rule selection may enter none of them.

- **Artifact identity.** The artifact lives inside the successful module's `.olean`, so toolchain,
  options, plugins, ordered imports, and dependency identity belong to it via Lake's own trace
  (`ArtifactModel.lean:29-35`). It must be a function of *the module and its source*, never of the
  rule set or of which rules are on. Today it is both, through `trailingWhitespace`
  (`ArtifactModel.lean:38`) and through the plugin's import of the rules (§3). §6 removes both.
- **Result-cache identity.** `CacheIdentity` (`Cache.lean:29-37`) is source digest, toolchain,
  environment, formatter, configuration, validation level, semantic schema. Selection is correctly
  absent. But `configuration` is `Project.configurationIdentity`, which for a module is
  `moduleConfiguration` (`Project.lean:229-240`), which includes `mod.leanOptions` — so
  `leanFmt.trailingWhitespace` is *in* the result-cache identity today. A rule selector reached
  cache identity. Removing the option removes it; `mod.leanOptions` stays, because the rest of it
  legitimately describes the module's build.
- **Selection.** `RulePlan.findings` filters after facts become findings. One cache entry serves
  every `--select`. Already true (`Semantic.lean:18-19`), and §6 makes it true of the artifact too.

The invariant, stated once: **an identity may depend on the file and how it is built, never on which
rules are on.** Turning a rule on must never rebuild or re-elaborate anything.

## 9. The inventory

Anticipated rules, from the roadmaps that own them, with the tier this model assigns.

| Rule / family | Stack | Tier | Note |
| --- | --- | --- | --- |
| FMT001 trailing whitespace | live | `source` | pure function of the normalized string |
| FMT002 final newline | live | `source` | ditto |
| mixed line endings | 08 | `source` | needs raw-vs-normalized; see §11 |
| UTF-8 BOM | 08 | `source` | ditto |
| forbidden control bytes | 08 | `source` | linear byte scan |
| bidirectional controls | 08 | `source` | linear byte scan |
| duplicate imports | 09 | `syntax` | the header projection |
| import order / grouping | 09 | `syntax` | ditto |
| redundant imports | 09 | `semantic` + graph | **does not close**; see §11 |
| module documentation | 10 | `syntax` | |
| namespace/module consistency | 10 | `syntax` | |
| duplicate attributes/modifiers | 10 | `syntax` | |
| mechanically redundant syntax | 10 | `syntax` | |
| deprecated declaration use | 11 | `semantic` | |
| unused binders / variables | 11 | `semantic` | |
| unused suppression directive | 07 | `syntax` | the directive is a lossless comment |

`ruff-08`'s roadmap independently requires its family to "work without syntax artifacts or frontend
construction and remain linear in source size" — that is the `source` tier restated, from a stack
written before this one. The two agree, which is weak evidence the tier boundary is in a natural
place rather than one this note invented.

The `syntax` column is where the tier model finally earns something: it is the first time
`RulePlan.requiredTier` can return a value that sends a run to `officialArtifacts`, and therefore
the first time `RFP-IMPL`'s stale-module hazard (`Application.lean:126-133`) is reachable from rule
selection rather than only from `format`.

## 10. What `RRE-IMPL` must implement

1. `Tier`, `SourceFacts`, `SyntaxFacts`, and the `RuleImpl` sum. `SemanticFacts` may be a stub with
   no constructor case in the registry until `ruff-11`, but the sum's shape is fixed here.
2. `ruleRegistry : Array Rule` with FMT001 and FMT002 as `.source` entries carrying their own
   implementations. `runRules` becomes a fold over the registry filtered by available tier, not a
   hard-coded concatenation.
3. Delete the option and every field, parameter, and lakefile line that carries it (§6). Bump the
   artifact schema to `v3`.
4. `RulePlan.requiredTier` replacing `RulePlan.requiresSyntax`; `availableAnalysis` and
   `officialArtifacts` gated on it and on `rendersCanonical`.
5. The regression §2 lacked: one test that runs *both* paths over one file and asserts identical
   findings. It must exercise the source-only shortcut, not only the artifact path — that is the gap
   `verify-official-facet` left.
6. A test that pins §3: editing a rule must not invalidate a module's Lake trace, while editing the
   projection must. `tests/compiler/run.sh:102-123` currently asserts only the second and cannot
   distinguish them.

Findings must remain byte-sorted deterministically across tiers; today ordering is positional by
construction (`Rules.lean:95` concatenates FMT001's before FMT002's) and that accident does not
survive a registry fold over mixed tiers.

## 11. Uncertainty

- **The redundant-import rule does not fit.** `ruff-09` requires "the exact Lake module graph plus a
  proof that removing an import preserves required direct dependencies". A rule may not hold project
  authority (this stack's stop rule), and the Lake graph is `LeanFmt.Project`'s (`AGENTS.md`). Part
  is module-local semantic evidence — which imports supplied constants this module referenced — and
  that fits `SemanticFacts` cleanly. The cross-module part does not fit any of the three tiers. This
  note does not invent a fourth tier for one unwritten rule; `ruff-09`'s `RIR-SPEC` owns the
  question, and it may find that the module-local half is all the rule needs. Named here so that
  stack does not discover the tier model silently excluded it.
- **`source` tier and raw bytes.** Every fact tier indexes the normalized string, and a module
  linter "is handed already-normalized text and cannot observe the file's bytes at all"
  (`AGENTS.md`). `ruff-08` wants BOM and mixed-line-ending rules, which are *about* the bytes
  normalization erased. `LosslessSource.normalize` returns the line-ending form alongside the
  normalized text, so the information exists at the reader, but `SourceFacts` as specified here does
  not carry it. Either `SourceFacts` gains an explicit raw-shape summary with its own coordinate
  discipline, or those rules are not `source`-tier in this model's sense. `RSR-SPEC` cannot answer
  this without `RRE-IMPL` having fixed `SourceFacts`; flagged rather than guessed.
- **Semantic fact shape is unspecified.** Deliberately. `ruff-11`'s `RMR-SPEC` owns "inventory Lean
  messages, info trees, environment extensions"; this note fixes only that they are immutable
  projections carried by the artifact and that no mutable `Environment` or `CoreM` action reaches a
  rule.
- **The option's removal is a product behavior change** for any project setting
  `leanFmt.trailingWhitespace=false`, which is public surface (`register_option`, so any project
  using the plugin can set it). Under the default it changes nothing. `--ignore FMT001` is the
  replacement, is already implemented, and is the only one of the two that `check` has ever honored
  — so for `check` users the change is from "silently ignored" to "gone", and for `format` users it
  is a rename. `RRE-IMPL` should say so in whatever release note this repository keeps; there is no
  deprecation window specified anywhere and this note does not invent one.
- **No measurement of what removing findings saves.** §3 measures the invalidation cost, not the
  artifact size or the `check`-path time. The size effect is small (findings are a handful of bytes
  against tokens and nodes at "about 25 B x (tokens + nodes)", `AGENTS.md`) and the argument here is
  architectural, not a size claim. `RRE-FINAL` should measure the rebuild fanout on the frozen
  sample rather than let §3's single-module result stand in for a project.
