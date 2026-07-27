module

public import LeanFmt.Analysis
public import LeanFmt.Application
public import LeanFmt.ArtifactStore
public import LeanFmt.Cache
public import LeanFmt.Cli
public import LeanFmt.Comments
public import LeanFmt.Config
public import LeanFmt.Discovery
public import LeanFmt.Doc
public import LeanFmt.Edit
public import LeanFmt.Formatter.NativeLayout
public import LeanFmt.Imports
public import LeanFmt.LanguageServer
public import LeanFmt.Rules
public import LeanFmt.Suppression
public import Test

import all LeanFmt.Analysis
import all LeanFmt.Application
import all LeanFmt.ArtifactStore
import all LeanFmt.Cache
import all LeanFmt.Cli
import all LeanFmt.Comments
import all LeanFmt.Config
import all LeanFmt.Discovery
import all LeanFmt.Doc
import all LeanFmt.Edit
import all LeanFmt.Formatter.NativeLayout
import all LeanFmt.Imports
import all LeanFmt.LanguageServer
import all LeanFmt.Rules
import all LeanFmt.Suppression
import all Test.Unit.Edit
import all Test.Unit.Fixtures

import Lean.Data.Lsp

open LeanFmt LeanFmt.Internal

open LeanFmt.Test.Unit.Fixtures
open LeanFmt.Test.Unit.Edit

namespace LeanFmt.Test.Unit.Rules

/- Rules run on the normalized source, never on the file's bytes. That is not a convenience: the
parser normalizes before it assigns any offset, so findings measured against raw bytes would land in
a different coordinate system than the projection they share an artifact with. -/
private def testRules : IO Unit := do
  let raw := "def x := 1  \r\n#check x\t"
  let (normalized, lineEndings) := LosslessSource.normalize raw
  ensure (lineEndings == .crlf) "a CRLF source was not recognized as CRLF"
  ensure (normalized == "def x := 1  \n#check x\t") "normalization is not crlfToLf"
  ensure (LosslessSource.denormalize normalized lineEndings == raw)
    "denormalize is not the inverse of normalize on accepted source"
  ensure ((LosslessSource.normalize normalized) == (normalized, .lf))
    "normalization is not idempotent"

  -- Trailing-whitespace and final-newline normalization is the **formatter's** layout, not a lint rule:
  -- both rules were retired, so the source rules are silent on both, even on
  -- this trailing-whitespace, no-final-newline fixture. The printer owns the normalization; that it does
  -- so soundly (never touching a string literal's interior) is proved in formatter/mode suites.
  --
  -- This once named the retired codes FMT001/FMT002 explicitly, in a `f.code != …` guard. The
  -- renumbering reassigned both codes to the live security rules, which
  -- would have turned that guard into "the security rules never fire" -- vacuously true on this
  -- fixture, and a silent hole exactly where the strongest rules are. The by-name guard is gone; the
  -- emptiness assertion below is what the case was always really claiming.
  let findings := runSourceRules normalized
  ensure (findings.isEmpty)
    "the default source rules should be silent on trailing whitespace and a missing final newline"

/-- `FMT001`/`FMT002`: forbidden control bytes and suspicious bidirectional controls. A control byte
or bidi mark only reaches accepted source inside a string literal or comment (bare occurrences are
parse errors), so those are the positions exercised here; ranges are
byte-exact in normalized coordinates and both rules are report-only. -/
private def testSourceSecurityRules : IO Unit := do
  let ctl (n : Nat) : String := String.ofList [Char.ofNat n]
  -- NUL inside a string literal, RLO (U+202E) inside a line comment.
  let src := "def s := \"a" ++ ctl 0x00 ++ "b\"\n-- x" ++ ctl 0x202e ++ "y\n"
  let security := (runSourceRules src).filter fun f => f.code == "FMT001" || f.code == "FMT002"
  ensure (security.map (·.code) == #["FMT001", "FMT002"])
    "control/bidi coverage or sort order changed"
  ensure (security.all fun f => f.fix?.isNone)
    "a source-security rule produced a fix; both are report-only by construction"
  ensure (security.all fun f => f.severity == .warning) "source-security severity changed"
  ensure (security[0]!.range == { start := 11, stop := 12 } &&
      security[0]!.message == "forbidden control byte U+0000")
    "FMT001 range or message is not byte-exact"
  ensure (security[1]!.range == { start := 19, stop := 22 } &&
      security[1]!.message == "suspicious bidirectional control U+202E")
    "FMT002 range is not the mark's exact three-byte span, or its message changed"
  -- A two-byte mark (ALM U+061C) gets a two-byte range: width is the scalar's, not a constant.
  let alm := (runSourceRules ("-- " ++ ctl 0x061c ++ "\n")).filter (·.code == "FMT002")
  ensure (alm.size == 1 && alm[0]!.range == { start := 3, stop := 5 } &&
      alm[0]!.message == "suspicious bidirectional control U+061C")
    "FMT002 width or zero-padded hex is wrong for a two-byte mark"
  -- DEL (0x7F) is forbidden; TAB (0x09) and LF (0x0A) are not.
  ensure (((runSourceRules ("-- " ++ ctl 0x7f ++ "\n")).filter (·.code == "FMT001")).size == 1)
    "DEL (0x7F) was not flagged as a forbidden control byte"
  ensure ((runSourceRules "def a := 1\n\tx := 2\n").all fun f => f.code != "FMT001" && f.code != "FMT002")
    "TAB or LF was flagged as a forbidden control byte"

/- Property/fuzz boundary test for the two source-security scans.

The live scans are checked differentially against an *independent* oracle: FMT001 by an explicit byte
predicate, FMT002 by explicit codepoint-list membership — neither reuses `Rules.lean`'s private
`isForbiddenControl`/`isBidiControl`, so a drift in either the byte set or the offset arithmetic fails
here. The oracle sorts by the same (start, stop, code) key `findingOrder` uses, so the comparison also
pins the sort. Inputs are generated by a deterministic LCG over a pool that mixes forbidden controls,
allowed controls (TAB/LF), every bidi width, safe ASCII, and safe multibyte scalars up to four bytes,
so a mark's byte offset must be carried correctly for the ranges to line up. The scan is a pure
function of the string — acceptance decides only which strings can *reach* it, never what it computes —
so feeding arbitrary generated strings tests strictly more than accepted source would. -/
private def testSourceSecurityProperties : IO Unit := do
  let forbidden (n : Nat) : Bool := (n < 0x20 && n != 0x09 && n != 0x0a) || n == 0x7f
  let bidiSet : List Nat :=
    [0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069]
  -- Independent expectation: FMT001 per forbidden byte, FMT002 per bidi scalar, in findingOrder.
  let oracle (s : String) : Array (String × Nat × Nat) := Id.run do
    let mut acc : Array (String × Nat × Nat) := #[]
    let bytes := s.toUTF8
    for i in [0:bytes.size] do
      if forbidden (bytes.get! i).toNat then acc := acc.push ("FMT001", i, i + 1)
    let mut pos := 0
    for c in s.toList do
      if bidiSet.contains c.toNat then acc := acc.push ("FMT002", pos, pos + c.utf8Size)
      pos := pos + c.utf8Size
    return acc.qsort fun a b =>
      if a.2.1 != b.2.1 then a.2.1 < b.2.1
      else if a.2.2 != b.2.2 then a.2.2 < b.2.2
      else a.1 < b.1
  let actual (s : String) : Array (String × Nat × Nat) :=
    (runSourceRules s).filterMap fun f =>
      if f.code == "FMT001" || f.code == "FMT002" then some (f.code, f.range.start, f.range.stop)
      else none
  let check (s : String) : IO Unit := do
    ensure (actual s == oracle s)
      "a source-security scan disagreed with the independent oracle on a generated input"
    ensure ((runSourceRules s).all fun f =>
        (f.code != "FMT001" && f.code != "FMT002") || f.fix?.isNone)
      "a source-security rule emitted a fix on a generated input; both are report-only"
  -- Pool: forbidden controls, allowed controls, every bidi width, safe ASCII, safe 2/3/4-byte scalars.
  let pool : Array Nat :=
    #[0x00, 0x07, 0x1b, 0x1f, 0x7f, 0x09, 0x0a,
      0x061c, 0x200f, 0x202a, 0x202e, 0x2066, 0x2069,
      0x41, 0x20, 0x30, 0x22, 0x2f, 0xe9, 0x4e2d, 0x1f600]
  let mut seed : Nat := 0x9e3779b9
  for _ in [0:120] do
    seed := (seed * 1103515245 + 12345) % 2147483648
    let len := seed % 48
    let mut s := ""
    for _ in [0:len] do
      seed := (seed * 1103515245 + 12345) % 2147483648
      s := s.push (Char.ofNat pool[seed % pool.size]!)
    check s
  -- Targeted edges the LCG need not hit: empty, all-forbidden run, control adjacent to a bidi mark,
  -- and a mark at the final byte position.
  check ""
  check (String.ofList (List.replicate 8 (Char.ofNat 0x00)))
  check (String.ofList [Char.ofNat 0x00, Char.ofNat 0x202e, Char.ofNat 0x1b])
  check (String.ofList [Char.ofNat 0x41, Char.ofNat 0x4e2d, Char.ofNat 0x202e])

/-- Catalog metadata invariants. Pure over the registry:
unique/well-shaped codes, namespace disjointness, lifecycle/default coherence, and documentation
presence. The *executable*-example check (each `bad` fires, each fix yields `good?`) runs through the
real frontend in `tests/catalog/run.sh`; this test pins everything answerable without a projection. -/
private def testCatalogInvariants : IO Unit := do
  let infos := allRuleInfos
  let codes := infos.map (·.code)
  -- 1. Codes are `FMT` + exactly three digits, unique, and disjoint from reserved + meta codes.
  let isCodeShaped := fun (c : String) =>
    let chars := c.toList
    chars.length == 6 && c.startsWith "FMT" && (chars.drop 3).all Char.isDigit
  for info in infos do
    ensure (isCodeShaped info.code) s!"rule code is not FMT###: {info.code}"
    ensure ((codes.filter (· == info.code)).size == 1) s!"duplicate rule code: {info.code}"
    ensure (!isReservedCode info.code) s!"live rule reuses a reserved code: {info.code}"
    ensure (info.code != "FMT900" && info.code != "FMT901")
      s!"live rule reuses a suppression meta code: {info.code}"
  -- 2. Namespace disjointness: no category names a code or a reserved word.
  for info in infos do
    ensure (!info.category.isEmpty) s!"rule {info.code} has an empty category"
    ensure (!isCodeShaped info.category) s!"category collides with a code shape: {info.category}"
    ensure (info.category != "all" && info.category != "default" && info.category != "preview")
      s!"category collides with a reserved word: {info.category}"
  -- 3. Lifecycle / default coherence.
  for info in infos do
    if info.lifecycle == .preview then
      ensure (!info.defaultEnabled) s!"preview rule is default-enabled: {info.code}"
    if info.lifecycle == .deprecated then
      ensure (!info.defaultEnabled) s!"deprecated rule is default-enabled: {info.code}"
      let some r := info.replacement?
        | throw <| IO.userError s!"deprecated rule {info.code} has no replacement"
      ensure (codes.contains r || isReservedCode r)
        s!"deprecated rule {info.code} names an unknown replacement: {r}"
    else
      ensure info.replacement?.isNone s!"non-deprecated rule {info.code} carries a replacement"
  -- 3b. Every preview rule states what would graduate it, and no other rule pretends to.
  --     Pinned in BOTH directions on purpose: a field that is merely
  --     *allowed* is a field that goes unset, and "not yet" with no condition is how a preview rule
  --     becomes permanent.
  for info in infos do
    if info.lifecycle == .preview then
      match info.previewPath? with
      | none => throw <| IO.userError s!"preview rule {info.code} states no path out of preview"
      | some p => ensure (!p.isEmpty) s!"preview rule {info.code} has an empty path out of preview"
    else
      ensure info.previewPath?.isNone
        s!"non-preview rule {info.code} carries a path out of preview"
  -- 4. Documentation: nonempty explanation always; ≥1 example unless exempt; a fixable non-exempt rule
  --    ships a bad→good example so its fix is testable.
  for info in infos do
    ensure (!info.explanation.isEmpty) s!"rule {info.code} has no explanation"
    if exampleExemptCodes.contains info.code then
      ensure info.examples.isEmpty s!"exempt rule {info.code} unexpectedly ships an example"
    else
      ensure (!info.examples.isEmpty) s!"rule {info.code} ships no example and is not exempt"
      ensure (info.examples.all (!·.bad.isEmpty)) s!"rule {info.code} has an empty example"
      if info.fixable then
        ensure (info.examples.any (·.good?.isSome))
          s!"fixable rule {info.code} has no bad→good example to test its fix"
      else
        ensure (info.examples.all (·.good?.isNone))
          s!"report-only rule {info.code} has a `good` example but nothing to fix"
  -- 5. Reserved integrity. `reservedCodes` is EMPTY after the pre-release renumbering, which reused
  -- the retired FMT001/FMT002 (docs/adding-a-rule.md §"Retiring a rule"). So the old form of this
  -- check -- "FMT001 and FMT002 are reserved and not live" -- is not merely failing, it asserts the
  -- opposite of what now holds, and it is gone rather than adjusted.
  --
  -- What survives is the invariant that does not depend on the table having entries: whatever is in
  -- it is disjoint from the live catalog. That is vacuously true today. It is asserted anyway, so the
  -- day a rule genuinely retires, the check is already here and already correct.
  --
  -- Deliberately NOT done: adding a placeholder retired code so this has something to bite on. A
  -- fixture invented to keep a test green proves the fixture exists, not that the machinery works.
  -- The reserved branches in `Config.selectorsValid` and `Suppression.apply` are untested until a
  -- real retirement, and `reservedCodes`' own docstring says so where someone will read it.
  for (code, _) in reservedCodes do
    ensure (!codes.contains code) s!"reserved code {code} reappeared as a live rule"
  -- 6. Generated docs are nonempty and one per live rule plus an index and the config schema (drift is
  -- checked in the harness). The schema enumerates exactly the selector vocabulary `selectorsValid` accepts.
  ensure (catalogDocs.size == infos.size + 2) "generated docs count does not match the catalog"
  ensure (catalogDocs.all (!·.2.isEmpty)) "a generated doc page is empty"
  ensure (catalogDocs.any (·.1 == "schema.json")) "the generated config schema is missing"
  for info in infos do
    ensure (selectorVocabulary.contains info.code)
      s!"live code {info.code} is absent from the schema selector vocabulary"
    ensure (selectorVocabulary.contains info.category)
      s!"category {info.category} is absent from the schema selector vocabulary"
  for (code, _) in reservedCodes do
    ensure (selectorVocabulary.contains code)
      s!"reserved code {code} is absent from the schema selector vocabulary"

private def testApplicability : IO Unit := do
  -- Admission: safe always, unsafe iff opted in, display-only never.
  ensure (Applicability.safe.admitted false && Applicability.safe.admitted true)
    "a safe fix was not admitted"
  ensure (!Applicability.unsafe.admitted false && Applicability.unsafe.admitted true)
    "unsafe admission did not track the opt-in"
  ensure (!Applicability.displayOnly.admitted false && !Applicability.displayOnly.admitted true)
    "a display-only fix was admitted"

  -- Wire round-trip and stable spellings.
  for (a, wire) in #[(Applicability.safe, "safe"), (.unsafe, "unsafe"), (.displayOnly, "display-only")] do
    ensure (a.toWire == wire) s!"applicability wire spelling changed for {wire}"
    ensure (match (Lean.fromJson? (Lean.toJson a) : Except String Applicability) with
      | .ok decoded => decoded == a | .error _ => false) s!"applicability did not round-trip: {wire}"
  ensure (match (Lean.fromJson? (.str "bogus") : Except String Applicability) with
    | .error _ => true | _ => false) "an unknown applicability wire value was accepted"

  -- Per-rule reclassification, resolved as a plan projection. Codes are opaque to `effectiveApplicability`;
  -- surviving fixable rules (`FMT011` syntax, `FMT012` semantic) stand in for the retired FMT001/FMT002.
  let plan : RulePlan := { selected := #["FMT011", "FMT012"], perFileIgnores := #[], extendSafe := #["FMT011"], extendUnsafe := #["FMT012"] }
  ensure (plan.effectiveApplicability "FMT011" .unsafe == .safe) "extend-safe-fixes did not promote"
  ensure (plan.effectiveApplicability "FMT011" .safe == .safe) "promotion changed an already-safe fix"
  ensure (plan.effectiveApplicability "FMT012" .safe == .unsafe) "extend-unsafe-fixes did not demote"
  ensure (plan.effectiveApplicability "FMT999" .safe == .safe) "an unlisted rule was reclassified"
  -- Display-only is a floor no promotion can lift.
  ensure (plan.effectiveApplicability "FMT011" .displayOnly == .displayOnly)
    "extend-safe-fixes promoted a display-only fix"

  -- `RulePlan.findings` carries the effective applicability onto the reported fix. Driven by a synthetic
  -- `.safe` fix (no source-tier fixable rule survives the layout retirement), which `extend-unsafe-fixes` demotes.
  let demote : RulePlan := { selected := #["FMT011"], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #["FMT011"] }
  let projected := demote.findings "A.lean" #[findingWithEdit { start := 0, stop := 1 } "" .safe "FMT011"]
  ensure (projected.size == 1 && (projected[0]!.fix?.map (·.applicability)) == some .unsafe)
    "the findings projection did not demote a safe fix"

  -- Conflict provenance names both rules, not array indices.
  match preparePatch "abc" #[
      findingWithEdit { start := 0, stop := 2 } "x" .safe "RULE_A",
      findingWithEdit { start := 1, stop := 3 } "y" .safe "RULE_B"
    ] with
  | .error error =>
    let rendered := toString error
    ensure ((rendered.splitOn "RULE_A").length == 2 && (rendered.splitOn "RULE_B").length == 2)
      s!"conflict error did not name both rules: {rendered}"
  | .ok _ => throw <| IO.userError "overlapping fixes were accepted"

  -- Contradiction: a rule in both extend lists is rejected at plan construction.
  let directory ← IO.FS.createTempDir
  try
    let configPath := directory / "lean-fmt.toml"
    IO.FS.writeFile configPath "extend-safe-fixes = [\"FMT011\"]\nextend-unsafe-fixes = [\"FMT011\"]\n"
    let config ← FormatterConfig.load directory
    ensure (match config.rulePlan {} with | .error _ => true | _ => false)
      "a rule in both extend lists was accepted"
  finally
    IO.FS.removeDirAll directory

/-! ## The engine, exercised at both tiers

`ruleRegistry` now mixes `syntax`-tier product rules with source ones — but it still cannot
exercise the *adversarial* seam this section pins: a `syntax` finding sorting **ahead** of a `source`
one despite being registered **after** it, and a `syntax` rule skipped cleanly when only `source`
facts are on hand. Pinning those needs two rules at controlled codes and ranges, which product rules
do not guarantee. The seam needs a representative rule at each tier, and fake product rules must not
be retained merely for coverage. Both hold at once only if the
representative rules live here and never enter `ruleRegistry` — which is what `runRulesOf` and
`requiredTierOf` take an array for.

These rules are deliberately trivial and deliberately adversarial about order: `probeSyntax` is
registered **last** and its findings land **first**, so an engine that concatenated in registry order
would fail every assertion below. -/

/-- `syntax`-tier: reports the projection's first token. Registered last, finds earliest. -/
private def probeSyntax : Rule := {
  info := {
    code := "TST900", category := "test", summary := "probe: first token"
    fixable := false, defaultEnabled := false, lifecycle := .preview
    explanation := "probe", examples := #[]
  }
  impl := .syntax fun facts =>
    match facts.projection.tokens[0]? with
    | none => #[]
    | some token => #[{
        code := "TST900", severity := .warning, message := "first token"
        range := { start := token.start, stop := token.stop }
      }]
}

/-- `source`-tier: reports the whole file. Shares its range with `probeTie` to pin tie-breaking. -/
private def probeSource : Rule := {
  info := {
    code := "TST901", category := "test", summary := "probe: whole file"
    fixable := false, defaultEnabled := false, lifecycle := .preview
    explanation := "probe", examples := #[]
  }
  impl := .source fun facts => #[{
    code := "TST901", severity := .warning, message := "whole file"
    range := { start := 0, stop := facts.bytes.size }
  }]
}

/-- `source`-tier, same range as `probeSource`, registered after it but ordering before it by code. -/
private def probeTie : Rule := {
  info := {
    code := "TST900", category := "test", summary := "probe: tie"
    fixable := false, defaultEnabled := false, lifecycle := .preview
    explanation := "probe", examples := #[]
  }
  impl := .source fun facts => #[{
    code := "TST900", severity := .warning, message := "tie"
    range := { start := 0, stop := facts.bytes.size }
  }]
}

private def testEngineTiers : IO Unit := do
  let normalized := fixtureSourceText
  let projection := fixtureLosslessSource
  let syntaxFacts := Facts.syntax (SyntaxFacts.of normalized projection)
  let sourceFacts := Facts.source (SourceFacts.of normalized)
  let registry := #[probeSource, probeSyntax]

  -- Mixed tiers, sorted by position and not by registry order. `probeSource` covers [0, 11) and
  -- `probeSyntax` finds the `def` token at [0, 3): same start, so the shorter range wins the tie.
  let mixed := runRulesOf registry syntaxFacts
  ensure (mixed.map (·.code) == #["TST900", "TST901"])
    "mixed-tier findings are not byte-sorted independently of registry order"
  ensure (mixed.map (fun finding => (finding.range.start, finding.range.stop)) == #[(0, 3), (0, 11)])
    "mixed-tier ranges are wrong or not sorted by stop within one start"

  -- The same registry against facts that cannot serve the `syntax` rule: it is skipped, not guessed
  -- at, not defaulted, and not an error. `requiredTierOf` is what makes the skip sound — it is what
  -- decided to obtain these facts, and it reads the same array.
  let skipped := runRulesOf registry sourceFacts
  ensure (skipped.map (·.code) == #["TST901"])
    "source facts did not skip exactly the syntax-tier rule"

  -- Ties inside one position break on the code, so registry order cannot decide output.
  let tied := runRulesOf #[probeSource, probeTie] sourceFacts
  ensure (tied.map (·.code) == #["TST900", "TST901"])
    "findings at one identical range are ordered by registry position rather than by code"
  let tiedReversed := runRulesOf #[probeTie, probeSource] sourceFacts
  ensure (tied == tiedReversed) "reordering the registry changed the output"

  -- A rule's tier is its implementation's, and `ToJson` derives `input` from it rather than reading
  -- a field. This is the drift `RuleInfo.input` allowed and `RuleImpl` makes unrepresentable.
  ensure (probeSyntax.tier == .syntax && probeSource.tier == .source) "Rule.tier is not RuleImpl.tier"
  let encoded := Lean.toJson probeSyntax
  ensure ((encoded.getObjValAs? String "input").toOption == some "syntax")
    "the rules wire shape does not derive input from the implementation"
  -- The first `.syntax`-tier rules (FMT006–FMT011) and the first `.semantic`-tier ones
  -- (FMT012–FMT015) shipped, so the registry now spans the whole lattice. The seams that
  -- once assumed it was uniformly source-tier are all tier-aware: `ofArtifact?` tags its cache entry
  -- with the tier the facts reached (`.semantic` for a demanded artifact, else `.syntax`) and the
  -- source-only shortcut tags `.source`, and `cacheHitServes` serves an entry only when
  -- `result.tier.satisfies plan.requiredTier` — so a narrow shortcut entry cannot answer a syntax or
  -- semantic `--select`. This asserts the shape: all three tiers now ship.
  ensure (ruleRegistry.any (·.tier == .source) && ruleRegistry.any (·.tier == .syntax) &&
      ruleRegistry.any (·.tier == .semantic))
    "ruleRegistry lost a tier: source+syntax shipped first, semantic was added later (FMT012–FMT015)"

  -- The lattice has `semantic` above `syntax`: richer facts serve any cheaper
  -- requirement, and the cheaper cannot serve the dearer. FMT012–FMT015 are the first
  -- shipped `.semantic`-tier rules, so both demanders now reach that tier — a `.semantic`-rule
  -- selection (below) and the canonical-rendering mode (`RulePlan.demandedTier`).
  ensure (Tier.satisfies .semantic .syntax && Tier.satisfies .semantic .source)
    "semantic facts failed to serve a cheaper requirement"
  ensure (!Tier.satisfies .syntax .semantic && !Tier.satisfies .source .semantic)
    "a cheaper tier was accepted for a semantic requirement"
  ensure (Tier.satisfies .semantic .semantic) "semantic facts did not serve a semantic requirement"
  ensure (Tier.max .syntax .semantic == .semantic && Tier.max .semantic .source == .semantic)
    "Tier.max disagrees with the source ≤ syntax ≤ semantic chain"

/-- Selection derives what a run must *obtain*, and nothing else.

Selection "never selects worker, artifact, cache, or
scheduling strategy" — the clause has two halves. This is the half about cost: what a selection is allowed to
make a run pay for. The other half, that selection stays out of cache identity, is
`tests/check/run.sh`'s one-entry-two-selections check, which needs a real cache and a real project.

`plan.selected` is what the fold reads, so these plans are built directly rather than through
`FormatterConfig.rulePlan`: the probe codes are not in `ruleRegistry` and `selectorsValid` would
rightly reject them. That is the seam working as intended — no fake rule is reachable from config. -/
private def testMixedSelection : IO Unit := do
  let registry := #[probeSource, probeSyntax]
  let plan (selected : Array String) : RulePlan :=
    { selected, perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] }

  ensure ((plan #[]).requiredTierOf registry == .source)
    "selecting nothing did not cost source facts"
  ensure ((plan #["TST901"]).requiredTierOf registry == .source)
    "selecting only a source rule cost more than source facts"
  ensure ((plan #["TST900"]).requiredTierOf registry == .syntax)
    "selecting a syntax rule did not require syntax facts"
  -- The point of `Tier.max`: one syntax rule in a mixed selection decides the whole batch, and its
  -- position in the array cannot matter.
  ensure ((plan #["TST900", "TST901"]).requiredTierOf registry == .syntax)
    "a mixed selection did not take the maximum of its rules' tiers"
  ensure ((plan #["TST901", "TST900"]).requiredTierOf #[probeSyntax, probeSource] == .syntax)
    "requiredTierOf depends on registry or selection order"
  -- An unselected syntax rule cannot make a run pay for facts nothing will read. This is the
  -- property that makes `--select` free: turning a rule off can never rebuild or re-elaborate.
  ensure ((plan #["TST901"]).requiredTierOf #[probeSyntax, probeSource] == .source)
    "an unselected syntax rule still cost the run its facts"
  -- And the derivation must agree with what the engine will actually run, or a batch obtains facts
  -- for rules it skips, or skips rules it obtained facts for.
  ensure ((runRulesOf registry (.source (SourceFacts.of fixtureSourceText))).map (·.code) ==
      #["TST901"])
    "requiredTierOf and runRulesOf disagree about what source facts can answer"
  -- Selecting exactly one shipped rule must cost exactly that rule's own tier — no more (paying for
  -- facts it will not read) and no less (skipping facts it needs). The shipped syntax rules make the
  -- `.syntax` side of this non-vacuous; before them every shipped rule was `.source`.
  ensure (ruleRegistry.all (fun rule => ({ selected := #[rule.code], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] } : RulePlan).requiredTier == rule.tier))
    "a shipped rule's single selection costs a different tier than the rule's own"

  -- Formatting does not demand semantic rule facts. Only the selected rules determine the tier.
  let shippedPlan : RulePlan :=
    { selected := #["FMT001"], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] }
  ensure (shippedPlan.demandedTier == .source)
    "a non-rendering run demanded more than its rules needed"
  -- Selecting a shipped `.semantic`-tier rule demands the semantic fact on its own, with no
  -- rendering — the second demander the mode is not. This is what makes a `check --select FMT012` run
  -- capture the compiler diagnostics rather than serve a syntax-only artifact that never held them.
  let semanticPlan : RulePlan :=
    { selected := #["FMT012"], perFileIgnores := #[], extendSafe := #[], extendUnsafe := #[] }
  ensure (semanticPlan.demandedTier == .semantic)
    "selecting a semantic rule did not demand the semantic fact without rendering"

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case := #[
  { name := "testRules", run := testRules },
  { name := "testSourceSecurityRules", run := testSourceSecurityRules },
  { name := "testSourceSecurityProperties", run := testSourceSecurityProperties },
  { name := "testEngineTiers", run := testEngineTiers },
  { name := "testMixedSelection", run := testMixedSelection },
  { name := "testCatalogInvariants", run := testCatalogInvariants },
  { name := "testApplicability", run := testApplicability }]

end LeanFmt.Test.Unit.Rules
