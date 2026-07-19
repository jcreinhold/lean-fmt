module

import all LeanFmt.Rules
import Lake.Toml.Load

namespace LeanFmt.Internal

private structure PathPattern where
  source : String
  segments : List String

private structure PerFileIgnore where
  pattern : PathPattern
  selectors : Array String

structure FormatterConfig where
  private mk ::
  includePatterns : Array PathPattern
  excludePatterns : Array PathPattern
  selectedSelectors : Array String
  /-- `extend-select` (`ruff-12` RRL-IMPL): selectors that *add* to the chosen selection without
  replacing it, so a project extends `default` without restating it. -/
  extendSelectSelectors : Array String
  ignoredSelectors : Array String
  perFileIgnores : Array PerFileIgnore
  extendSafeFixes : Array String
  extendUnsafeFixes : Array String
  /-- The fix-selection axis (`ruff-12`), orthogonal to rule selection and to safe/unsafe: which rules'
  fixes `fix` may apply. `fixable` replaces the base (default `all`), `extend-fixable` adds, `unfixable`
  removes; resolved by the same specificity model as select/ignore. A selected-but-unfixable rule is
  still reported — only its fix is withheld. -/
  fixableSelectors : Array String
  unfixableSelectors : Array String
  extendFixableSelectors : Array String
  /-- Preview mode (`ruff-12`): with it off, `all`/`default`/category expand to stable rules only and an
  explicit preview-code selection is an error; with it on, preview rules become reachable. -/
  preview : Bool

structure RulePlan where
  private mk ::
  selected : Array String
  /-- Codes whose fixes `fix` may apply — the fix-selection axis resolved over the selected set
  (`fixable`/`unfixable`/`extend-fixable`, `notes/01-schema.md` §6). A selected code absent here is
  reported but its fix is withheld from the patch, exactly as an unadmitted unsafe fix is. -/
  fixableSelected : Array String := #[]
  perFileIgnores : Array PerFileIgnore
  /-- Rule codes whose fixes are promoted to safe, and demoted to unsafe. Resolved from
  `extend-safe-fixes`/`extend-unsafe-fixes`; a code in both is rejected at plan construction, so the
  two arrays are disjoint by the time they land here. Display-only is never in either — it is a floor
  configuration cannot lift (`notes/01-model.md` §2). -/
  extendSafe : Array String
  extendUnsafe : Array String
  /-- Non-fatal notices raised while resolving selectors — a retired/reserved code named in a selector,
  or a deprecated rule selected explicitly (`notes/01-schema.md` §7). The IO caller (`Application`,
  `Service`) prints these to stderr; they never change exit status or which rules run. -/
  notices : Array String := #[]

/-- Every CLI-side selection input, bundled so `rulePlan` takes one argument instead of seven. Each
field mirrors a `--flag`; empty/false is "not given on the CLI". -/
structure CliSelection where
  select : Array String := #[]
  extendSelect : Array String := #[]
  ignore : Array String := #[]
  fixable : Array String := #[]
  unfixable : Array String := #[]
  extendFixable : Array String := #[]
  preview : Bool := false

private def normalizePath (path : String) : String :=
  path.replace "\\" "/" |>.dropPrefix "./" |>.toString

private def validPatternSegment (segment : String) : Bool :=
  !segment.isEmpty && segment != "." && segment != ".." &&
    (!segment.contains "**" || segment == "**")

private def compilePattern (source : String) : Except String PathPattern := do
  let normalized := normalizePath source
  unless !normalized.isEmpty && !normalized.startsWith "/" do
    throw s!"invalid path pattern '{source}': expected a nonempty relative pattern"
  let segments := normalized.splitOn "/"
  unless segments.all validPatternSegment do
    throw s!"invalid path pattern '{source}': '**' must be a complete component and '.'/'..' are forbidden"
  return { source := normalized, segments }

private partial def segmentMatches : List Char → List Char → Bool
  | [], [] => true
  | [], _ => false
  | '*' :: pattern, text =>
    segmentMatches pattern text ||
      match text with
      | [] => false
      | _ :: rest => segmentMatches ('*' :: pattern) rest
  | '?' :: pattern, _ :: text => segmentMatches pattern text
  | '?' :: _, [] => false
  | expected :: pattern, actual :: text =>
    expected == actual && segmentMatches pattern text
  | _ :: _, [] => false

private partial def pathMatches : List String → List String → Bool
  | [], [] => true
  | [], _ => false
  | "**" :: pattern, path =>
    pathMatches pattern path ||
      match path with
      | [] => false
      | _ :: rest => pathMatches ("**" :: pattern) rest
  | expected :: pattern, actual :: path =>
    segmentMatches expected.toList actual.toList && pathMatches pattern path
  | _ :: _, [] => false

private def PathPattern.matches (pattern : PathPattern) (path : String) : Bool :=
  pathMatches pattern.segments ((normalizePath path).splitOn "/")

private def valueStrings (key : String) : Lake.Toml.Value → Except String (Array String)
  | .array _ values => values.mapM fun
    | .string _ value => .ok value
    | _ => .error s!"configuration key '{key}' expects an array of strings"
  | _ => .error s!"configuration key '{key}' expects an array of strings"

private def keyString : Lean.Name → String
  | .str .anonymous value => value
  | name => name.toString

/-- A selector names a category iff some rule declares it. Categories are derived from the full rule
identity set (`allRuleInfos` = engine rules + import rules), never a hardcoded list: a new category
(`security`, `imports`) becomes selectable the moment a rule carries it, and
`expandSelector`/`selectorsValid` cannot drift apart. Reading `allRuleInfos` rather than `ruleRegistry`
is what makes `--select imports` and FMT005/6/7 selectable even though those rules live outside the
linear-tier engine. -/
private def isCategory (selector : String) : Bool :=
  allRuleInfos.any (·.category == selector)

/-- A selector token is valid if it is a meta selector, a category, a live code, or a **reserved/retired
code** (`notes/01-schema.md` §7). Reserved codes are accepted rather than rejected so a legacy config
that still names FMT001/FMT002 keeps loading; they resolve to no live rule and raise a notice at plan
time (`rulePlan`). -/
private def selectorsValid (selectors : Array String) : Except String Unit := do
  for selector in selectors do
    unless selector == "all" || selector == "default" || isCategory selector ||
        allRuleInfos.any (·.code == selector) || isReservedCode selector do
      throw s!"unknown rule selector: {selector}"

private def parsePerFileIgnores (value : Lake.Toml.Value) : Except String (Array PerFileIgnore) := do
  let .table _ table := value
    | throw "configuration key 'per-file-ignores' expects a table"
  table.items.mapM fun (key, value) => do
    let pattern ← compilePattern (keyString key)
    let selectors ← valueStrings s!"per-file-ignores.{key}" value
    selectorsValid selectors
    return { pattern, selectors }

private def defaultConfig : FormatterConfig := {
  includePatterns := #[]
  excludePatterns := #[]
  selectedSelectors := #["default"]
  extendSelectSelectors := #[]
  ignoredSelectors := #[]
  perFileIgnores := #[]
  extendSafeFixes := #[]
  extendUnsafeFixes := #[]
  fixableSelectors := #[]
  unfixableSelectors := #[]
  extendFixableSelectors := #[]
  preview := false
}

private def parseConfig (table : Lake.Toml.Table) : Except String FormatterConfig := do
  let mut includePatterns := #[]
  let mut excludePatterns := #[]
  let mut selectedSelectors := #["default"]
  let mut extendSelectSelectors := #[]
  let mut ignoredSelectors := #[]
  let mut perFileIgnores := #[]
  let mut extendSafeFixes := #[]
  let mut extendUnsafeFixes := #[]
  let mut fixableSelectors := #[]
  let mut unfixableSelectors := #[]
  let mut extendFixableSelectors := #[]
  let mut preview := false
  for (key, value) in table.items do
    match keyString key with
    | "include" =>
      let sources ← valueStrings "include" value
      includePatterns ← sources.mapM compilePattern
    | "exclude" =>
      let sources ← valueStrings "exclude" value
      excludePatterns ← sources.mapM compilePattern
    | "select" => selectedSelectors ← valueStrings "select" value
    | "extend-select" => extendSelectSelectors ← valueStrings "extend-select" value
    | "ignore" => ignoredSelectors ← valueStrings "ignore" value
    | "per-file-ignores" => perFileIgnores ← parsePerFileIgnores value
    | "extend-safe-fixes" => extendSafeFixes ← valueStrings "extend-safe-fixes" value
    | "extend-unsafe-fixes" => extendUnsafeFixes ← valueStrings "extend-unsafe-fixes" value
    | "fixable" => fixableSelectors ← valueStrings "fixable" value
    | "unfixable" => unfixableSelectors ← valueStrings "unfixable" value
    | "extend-fixable" => extendFixableSelectors ← valueStrings "extend-fixable" value
    | "preview" =>
      match value with
      | .boolean _ b => preview := b
      | _ => throw "configuration key 'preview' expects a boolean"
    | unknown => throw s!"unknown configuration key: {unknown}"
  selectorsValid selectedSelectors
  selectorsValid extendSelectSelectors
  selectorsValid ignoredSelectors
  selectorsValid extendSafeFixes
  selectorsValid extendUnsafeFixes
  selectorsValid fixableSelectors
  selectorsValid unfixableSelectors
  selectorsValid extendFixableSelectors
  return {
    includePatterns := includePatterns
    excludePatterns := excludePatterns
    selectedSelectors := selectedSelectors
    extendSelectSelectors := extendSelectSelectors
    ignoredSelectors := ignoredSelectors
    perFileIgnores := perFileIgnores
    extendSafeFixes := extendSafeFixes
    extendUnsafeFixes := extendUnsafeFixes
    fixableSelectors := fixableSelectors
    unfixableSelectors := unfixableSelectors
    extendFixableSelectors := extendFixableSelectors
    preview := preview
  }

private def loadTable (path : System.FilePath) : IO Lake.Toml.Table := do
  let input ← IO.FS.readFile path
  let context := Lean.Parser.mkInputContext input path.toString
  match ← Lake.Toml.loadToml context |>.toBaseIO with
  | .ok table => return table
  | .error messages =>
    let rendered ← messages.toArray.mapM (·.toString)
    throw <| IO.userError s!"invalid formatter configuration {path}: \
      {String.intercalate "; " rendered.toList}"

/-- Load all formatter policy in one step. An explicit path must exist; an absent conventional
`lean-fmt.toml` is the default policy rather than an error. -/
def FormatterConfig.load (root : System.FilePath)
    (explicit? : Option System.FilePath := none) : IO FormatterConfig := do
  let path := explicit?.getD (root / "lean-fmt.toml")
  unless ← path.pathExists do
    if explicit?.isSome then
      throw <| IO.userError s!"formatter configuration does not exist: {path}"
    return defaultConfig
  match parseConfig (← loadTable path) with
  | .ok config => return config
  | .error message => throw <| IO.userError s!"invalid formatter configuration {path}: {message}"

/-- Whether a discovered root-package module survives configured path selection. Empty `include`
means every root module; excludes always win. Explicit CLI files bypass this predicate. -/
def FormatterConfig.includesPath (config : FormatterConfig) (path : String) : Bool :=
  (config.includePatterns.isEmpty || config.includePatterns.any (·.matches path)) &&
    !config.excludePatterns.any (·.matches path)

/-- Expand a selector to the codes it names, for the **subtractive** contexts (per-file-ignores and
`extend-safe/unsafe-fixes`) that project a set of codes and test containment. `all`/`default`/category
follow `defaultEnabled`/category; a bare code (live or reserved) is itself. These contexts never need
the preview gate or specificity — they only remove or reclassify — so they keep the flat expansion.
Positive selection (`select`/`ignore`/`fixable`) instead goes through `resolveAxis`. -/
private def expandSelector (selector : String) : Array String :=
  if selector == "all" then
    allRuleInfos.map (·.code)
  else if selector == "default" then
    allRuleInfos.filter (·.defaultEnabled) |>.map (·.code)
  else if isCategory selector then
    allRuleInfos.filter (·.category == selector) |>.map (·.code)
  else
    #[selector]

private def expandSelectors (selectors : Array String) : Array String :=
  selectors.foldl (init := #[]) fun codes selector =>
    (expandSelector selector).foldl (init := codes) fun codes code =>
      if codes.contains code then codes else codes.push code

/-- The specificity of a selector token (`notes/01-schema.md` §5.4): an exact code (3) is more specific
than a category (2), which is more specific than `all`/`default` (1). A reserved code or unrecognized
token has specificity 0 and mentions no live rule. -/
private def selectorSpecificity (selector : String) : Nat :=
  if selector == "all" || selector == "default" then 1
  else if isCategory selector then 2
  else if allRuleInfos.any (·.code == selector) then 3
  else 0

/-- Whether `selector` names live rule `info`, honoring the **preview gate** (§5.3): `all` and a
category expand to stable rules only unless `preview` is on (then their preview rules too); `default`
follows `defaultEnabled` (only stable rules are default-on); a deprecated rule is reached only by its
exact code; an exact-code selector names exactly its own code. -/
private def selectorMentions (preview : Bool) (selector : String) (info : RuleInfo) : Bool :=
  let gated := info.lifecycle == .stable || (info.lifecycle == .preview && preview)
  if selector == "all" then gated
  else if selector == "default" then info.defaultEnabled
  else if isCategory selector then info.category == selector && gated
  else selector == info.code

/-- Resolve one selection axis over `universe` by specificity (§5.4): a rule is enabled iff some
`enable` selector names it and **strictly outranks** every `disable` selector that names it — a tie goes
to the disabler ("ignore wins"). `preview` gates what `all`/category mention. -/
private def resolveAxis (pool : Array RuleInfo) (preview : Bool)
    (enable disable : Array String) : Array String :=
  let best := fun (tokens : Array String) (info : RuleInfo) =>
    tokens.foldl (init := 0) fun acc t =>
      if selectorMentions preview t info then Nat.max acc (selectorSpecificity t) else acc
  pool.filterMap fun info =>
    let e := best enable info
    let d := best disable info
    if e > 0 && e > d then some info.code else none

/-- Resolve CLI/config selection into a `RulePlan` (`notes/01-schema.md` §5–§6). A nonempty CLI
`--select` replaces configured `select` and its configured ignores; `extend-select` always adds;
ignores within the chosen layer always apply. Resolution is by specificity (`resolveAxis`), not flat
subtraction: `--select FMT010 --ignore redundancy` keeps FMT010, because an exact selector outranks a
category. The preview gate (§5.3) errors on an explicit preview-code selection when preview is off, and
raises a non-fatal notice for a reserved/retired or deprecated code named in a selector. -/
def FormatterConfig.rulePlan (config : FormatterConfig) (cli : CliSelection) :
    Except String RulePlan := do
  selectorsValid cli.select
  selectorsValid cli.extendSelect
  selectorsValid cli.ignore
  selectorsValid cli.fixable
  selectorsValid cli.unfixable
  selectorsValid cli.extendFixable
  let preview := config.preview || cli.preview
  let cliOwnsSelection := !cli.select.isEmpty
  let selectTokens := if cliOwnsSelection then cli.select else config.selectedSelectors
  let extendSelectTokens := config.extendSelectSelectors ++ cli.extendSelect
  let ignoreTokens := (if cliOwnsSelection then #[] else config.ignoredSelectors) ++ cli.ignore
  let enableTokens := selectTokens ++ extendSelectTokens
  -- Preview gate: an explicit exact-code selection of a preview rule is an error unless preview is on —
  -- a specific message, never a silent drop. A category/`all` simply omits preview rules when off.
  for t in enableTokens do
    if let some info := allRuleInfos.find? (·.code == t) then
      if info.lifecycle == .preview && !preview then
        throw s!"rule {t} is in preview; enable preview mode (--preview) to select it"
  -- Non-fatal notices: a reserved/retired code, or a deprecated rule, named in any selector.
  let mut notices := #[]
  for t in enableTokens ++ ignoreTokens do
    if isReservedCode t then
      notices := notices.push
        s!"selector {t} names no live rule ({(reservedDisposition? t).getD "reserved code"})"
    else if let some info := allRuleInfos.find? (·.code == t) then
      if info.lifecycle == .deprecated then
        let migration := match info.replacement? with | some r => s!"; use {r} instead" | none => ""
        notices := notices.push s!"rule {t} is deprecated{migration}"
  let selected := resolveAxis allRuleInfos preview enableTokens ignoreTokens
  -- Fix-selection axis, resolved over the *selected* set (already preview-gated, so mention with
  -- `preview := true`). Base is `all` unless `fixable` is configured; `extend-fixable` adds, `unfixable`
  -- removes. A selected-but-unfixable code stays reported; only its fix is withheld (`prepareFile`).
  let fixableOwns := !cli.fixable.isEmpty
  let fixEnable := (if fixableOwns then cli.fixable
      else if config.fixableSelectors.isEmpty then #["all"] else config.fixableSelectors)
    ++ config.extendFixableSelectors ++ cli.extendFixable
  let fixDisable := (if fixableOwns then #[] else config.unfixableSelectors) ++ cli.unfixable
  let selectedInfos := allRuleInfos.filter (selected.contains ·.code)
  let fixableSelected := resolveAxis selectedInfos true fixEnable fixDisable
  -- Reclassification is config-only; there is no CLI spelling, so it is resolved once here from the
  -- config's own lists. A rule in both is a contradiction, not last-writer-wins.
  let extendSafe := expandSelectors config.extendSafeFixes
  let extendUnsafe := expandSelectors config.extendUnsafeFixes
  for code in extendSafe do
    if extendUnsafe.contains code then
      throw s!"rule {code} is in both extend-safe-fixes and extend-unsafe-fixes"
  return {
    selected
    fixableSelected
    perFileIgnores := config.perFileIgnores
    extendSafe
    extendUnsafe
    notices
  }

private def ignoredForPath (plan : RulePlan) (path code : String) : Bool :=
  plan.perFileIgnores.any fun entry =>
    entry.pattern.matches path && (expandSelectors entry.selectors).contains code

/-- The effective applicability of `code`'s fix, after per-rule reclassification. Display-only is a
floor no promotion can lift; otherwise `extend-safe-fixes` promotes and `extend-unsafe-fixes` demotes.
The two lists are disjoint (checked at plan construction), so the order of these tests is immaterial.

A projection, never read by a rule: like selection, reclassification lives in the plan so that turning
a fix safe cannot re-elaborate anything and a rule cannot decide its own admission. -/
def RulePlan.effectiveApplicability (plan : RulePlan) (code : String)
    (base : Applicability) : Applicability :=
  match base with
  | .displayOnly => .displayOnly
  | _ =>
    if plan.extendSafe.contains code then .safe
    else if plan.extendUnsafe.contains code then .unsafe
    else base

/-- Project canonical findings onto this plan: keep the selected, non-per-file-ignored ones, and
rewrite each surviving fix's applicability to its effective value. The reported findings therefore
carry the applicability a user will act on; admission (which of them `fix` applies) is a separate,
downstream decision (`Applicability.admitted`). -/
def RulePlan.findings (plan : RulePlan) (path : String)
    (findings : Array Finding) : Array Finding :=
  (findings.filter fun finding =>
    plan.selected.contains finding.code && !ignoredForPath plan path finding.code).map
    fun finding =>
      match finding.fix? with
      | some fix =>
        let applicability := plan.effectiveApplicability finding.code fix.applicability
        { finding with fix? := some { fix with applicability } }
      | none => finding

def RulePlan.activeCount (plan : RulePlan) : Nat := plan.selected.size

/-- The cheapest facts that can answer every selected rule of `rules`.

This is the projection the roadmap asks for: selection derives what a run must *obtain*, and nothing
else. It does not decide a worker, an artifact strategy, a cache identity, or an order — a run that
selects nothing costs `source`, and turning a rule on can never rebuild or re-elaborate anything.

The mode contributes separately (`RunMode.rendersCanonical`): a rendering mode needs the projection
whatever its rules need.

`rules` is a parameter for the same reason `runRulesOf` takes one, and must stay in step with it: the
two derive from one array or they can disagree about what a selection costs. Only tests pass their
own; every production caller goes through `requiredTier`. -/
def RulePlan.requiredTierOf (plan : RulePlan) (rules : Array Rule) : Tier :=
  rules.foldl (init := .source) fun tier rule =>
    if plan.selected.contains rule.code then tier.max rule.tier else tier

/-- The cheapest facts that can answer every selected rule the product ships. -/
def RulePlan.requiredTier (plan : RulePlan) : Tier := plan.requiredTierOf ruleRegistry

/-- The tier a run must actually obtain, folding in the mode's own demand on top of its rules'.

Rules alone give `requiredTier`; the mode contributes separately, because a rendering mode needs facts
its rules do not. The declared-spacing fact (`Tier.semantic`) is consumed by the **formatter**, not by
any rule, so `requiredTier` — a fold over rules — can never reach `semantic` on its own (`ruff-05b`).
A canonical-rendering run demands it here instead: `format`/`diff`/`fix` obtain the semantic artifact,
`check` and a source/syntax report do not. This is the one place the formatter's demand enters
planning, so the gating cost is recorded rather than hidden across call sites. -/
def RulePlan.demandedTier (plan : RulePlan) (renderCanonical : Bool) : Tier :=
  plan.requiredTier.max (if renderCanonical then .semantic else .source)

/-- Whether the plan selects a rule whose fix reads the owned deprecation-occurrence fact. Governs the
`occurrences` capability and the info-tree fold's cost (`RuleInfo.needsOccurrences`). `rules` is a
parameter for the same reason `requiredTierOf` takes one — capture cost and rule execution derive from
one registry or they disagree about what a selection costs. -/
def RulePlan.selectsOccurrenceRuleOf (plan : RulePlan) (rules : Array Rule) : Bool :=
  rules.any fun rule => plan.selected.contains rule.code && rule.info.needsOccurrences

def RulePlan.selectsOccurrenceRule (plan : RulePlan) : Bool :=
  plan.selectsOccurrenceRuleOf ruleRegistry

/-- The semantic sub-facts a run demands — the capability axis beside `demandedTier` (`ruff-11b`
Design B). Non-empty only when the demanded tier reaches `.semantic`:
- `notations` when a rendering mode needs the layout fact (`format`/`diff`; `fix` does not reflow);
- `diagnostics` when a selected rule reads the compiler diagnostics (the tier reached `.semantic`
  through a rule) — always satisfied by any `.semantic` entry, which captures it monolithically;
- `occurrences` when a run that **applies** fixes selects an occurrence-fix rule (FMT014's rename) — the
  one capability that gates the whole-file info-tree fold.

The `occurrences` demand keys off `applies` (true only for `fix`), not off `renderCanonical`, since
`ruff-11c` RDF-IMPL split layout from fix: `format`/`diff` render (`renderCanonical`) but apply no fix,
so they must not pay the info-tree fold, while `fix` applies the FMT014 rename but no longer renders. A
`check` neither renders nor applies, so it demands neither `notations` nor `occurrences`. `cacheHitServes`
serves a `.semantic` entry only when `demandedCaps.subset entry.caps`, so a fix's `occurrences` demand
misses a monolithic-era entry that never captured it. -/
def RulePlan.demandedCaps (plan : RulePlan) (renderCanonical applies : Bool) : SemanticCaps :=
  if plan.demandedTier renderCanonical == .semantic then
    { notations := renderCanonical
      diagnostics := plan.requiredTier == .semantic
      occurrences := applies && plan.selectsOccurrenceRule }
  else {}

end LeanFmt.Internal
