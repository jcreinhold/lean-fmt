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
  ignoredSelectors : Array String
  perFileIgnores : Array PerFileIgnore

structure RulePlan where
  private mk ::
  selected : Array String
  perFileIgnores : Array PerFileIgnore

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

private def selectorsValid (selectors : Array String) : Except String Unit := do
  for selector in selectors do
    unless selector == "all" || selector == "text" ||
        ruleRegistry.any (·.info.code == selector) do
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
  selectedSelectors := #["all"]
  ignoredSelectors := #[]
  perFileIgnores := #[]
}

private def parseConfig (table : Lake.Toml.Table) : Except String FormatterConfig := do
  let mut includePatterns := #[]
  let mut excludePatterns := #[]
  let mut selectedSelectors := #["all"]
  let mut ignoredSelectors := #[]
  let mut perFileIgnores := #[]
  for (key, value) in table.items do
    match keyString key with
    | "include" =>
      let sources ← valueStrings "include" value
      includePatterns ← sources.mapM compilePattern
    | "exclude" =>
      let sources ← valueStrings "exclude" value
      excludePatterns ← sources.mapM compilePattern
    | "select" => selectedSelectors ← valueStrings "select" value
    | "ignore" => ignoredSelectors ← valueStrings "ignore" value
    | "per-file-ignores" => perFileIgnores ← parsePerFileIgnores value
    | unknown => throw s!"unknown configuration key: {unknown}"
  selectorsValid selectedSelectors
  selectorsValid ignoredSelectors
  return { includePatterns, excludePatterns, selectedSelectors, ignoredSelectors, perFileIgnores }

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

private def expandSelector (selector : String) : Array String :=
  if selector == "all" then
    ruleRegistry.map (·.info.code)
  else if selector == "text" then
    ruleRegistry.filter (·.info.category == "text") |>.map (·.info.code)
  else
    #[selector]

private def expandSelectors (selectors : Array String) : Array String :=
  selectors.foldl (init := #[]) fun codes selector =>
    (expandSelector selector).foldl (init := codes) fun codes code =>
      if codes.contains code then codes else codes.push code

/-- Resolve CLI/config precedence once. A nonempty CLI select replaces configured selection and its
configured ignores; otherwise configured selection is used. CLI ignores always apply to the chosen
selection, and ignores win over selects within that layer. -/
def FormatterConfig.rulePlan (config : FormatterConfig) (cliSelect cliIgnore : Array String) :
    Except String RulePlan := do
  selectorsValid cliSelect
  selectorsValid cliIgnore
  let cliOwnsSelection := !cliSelect.isEmpty
  let selectedBy := if cliOwnsSelection then cliSelect else config.selectedSelectors
  let ignoredBy := if cliOwnsSelection then cliIgnore else config.ignoredSelectors ++ cliIgnore
  let ignored := expandSelectors ignoredBy
  let selected := expandSelectors selectedBy |>.filter (!ignored.contains ·)
  return {
    selected
    perFileIgnores := config.perFileIgnores
  }

private def ignoredForPath (plan : RulePlan) (path code : String) : Bool :=
  plan.perFileIgnores.any fun entry =>
    entry.pattern.matches path && (expandSelectors entry.selectors).contains code

def RulePlan.findings (plan : RulePlan) (path : String)
    (findings : Array Finding) : Array Finding :=
  findings.filter fun finding =>
    plan.selected.contains finding.code && !ignoredForPath plan path finding.code

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

end LeanFmt.Internal
