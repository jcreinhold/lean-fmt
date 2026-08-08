/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Imports
import all LeanFmt.Rules

import Lake.Toml.Load

/-! Discovered configuration: the TOML files, how they combine, and the rule plan that comes out.

Configuration is discovered per directory and inherited, so a pattern means what its *declaring*
file's directory says it means. That is why every path pattern carries its own anchor instead of
being re-read against whatever file is being checked.

`rulePlan` joins the config with the command line, and it is a projection over canonical results: it
selects rules and re-applies applicability afterwards. It does not enter execution strategy and it
does not enter cache identity, so turning a rule on cannot rebuild anything. -/

namespace LeanFmt.Internal

private structure PathPattern where
  source : String
  segments : List String
  /-- The directory this pattern is anchored at, relative to the project root (`""` is the
  root itself). A pattern means what its **declaring** config's directory says it means, never what
  the consuming file's directory does. With one root config the two
  agree, so the field has to be explicit to keep them apart: a nested config's
  `exclude = ["Generated/**"]` means `Generated/**` under *that* config's directory, and an
  `extend`ed pattern keeps its parent's anchor rather than being re-anchored at the inheritor. -/
  anchor : String := ""

private structure PerFileIgnore where
  pattern : PathPattern
  selectors : Array String

/-- Where a declaration's body goes relative to `:=` (`declaration-body`). -/
inductive DeclarationBody where
  /-- The canonical style (`next-line`, default): the body begins on its own line —
  `def foo :=` then `  1`. -/
  | nextLine
  /-- Keep the body on the `:=` line when the joined line fits `line-width`, joining
  already-broken bodies that fit; break as `next-line` when it does not. -/
  | sameLine
  deriving BEq, Lean.ToJson, Lean.FromJson

instance : ToString DeclarationBody where
  toString
    | .nextLine => "next-line"
    | .sameLine => "same-line"

/-- Where a `where`-form declaration's `where` goes relative to its signature
(`declaration-where`).

Separate from `declaration-body` because the two answer independent questions: mathlib's house
style is the canonical `next-line` body with `where` on the signature row, which one key cannot
spell. -/
inductive DeclarationWhere where
  /-- The default (`same-line`): `where` rides the signature row whenever the joined row fits
  `line-width`, and starts its own line when it does not. -/
  | sameLine
  /-- `where` always begins its own line, whatever the signature's width. -/
  | nextLine
  deriving BEq, Lean.ToJson, Lean.FromJson

instance : ToString DeclarationWhere where
  toString
    | .sameLine => "same-line"
    | .nextLine => "next-line"

/-- How a trailing `,` in a collection literal steers its layout (`magic-trailing-comma`). -/
inductive MagicTrailingComma where
  /-- The canonical style (`respect`, default), ruff's and black's: a collection whose source
  spells a trailing `,` before the closing bracket explodes -- one element per row, closing
  bracket on its own dedented row. Without a trailing comma, width alone decides.
  -/
  | respect
  /-- A trailing `,` is preserved but ignored for layout: width alone decides, and an exploded
  collection whose trailing comma is removed is free to rejoin. -/
  | ignore
  deriving BEq, Lean.ToJson, Lean.FromJson

instance : ToString MagicTrailingComma where
  toString
    | .respect => "respect"
    | .ignore => "ignore"

/-- The `[format]` section: settings that change the **canonical bytes** a run produces.

The section split marks the cache-identity boundary, not a cosmetic grouping:
every field here is folded into
`Project.configurationIdentity`, because a cached `CanonicalLayout` rendered under one value must
never be served under another. `[lint]` settings are the complement — they project over an
unchanged canonical result and must stay out of identity, as `CLAUDE.md` requires of rule
selection. -/
structure FormatConfig where private mk ::
  /-- The render margin (`line-width`), default 100.

  Promoting this from the compile-time `Application.canonicalWidth` required a new cache-identity
  input. Formatter identity is `(path, byteSize, mtime)` of the executable, so editing a *constant*
  still invalidates — a rebuild rewrites the file — but a *runtime* override changes output without
  touching the binary. Hence `identityString`. -/
  lineWidth : Nat := 100
  /-- Inline comments containing any of these phrases are pinned (`pinned-comments`), default
  `["shake: keep"]` : the formatter never moves them and never splits their line, even when the
  code alone overflows — a pinned directive must not dangle off a construct it annotates. -/
  pinnedComments : Array String := #["shake: keep"]
  /-- Whether standalone `--` comment blocks whose lines overflow `line-width` are rewrapped to
  fit (`reflow-comments`), default `false` (off). Empty comment lines and list-item lines break
  a block into independently rewrapped sub-blocks; a comment naming a `pinned-comments` phrase
  is never touched. Only standalone leading line comments qualify -- trailing comments, doc
  comments, and block comments keep their bytes. -/
  reflowComments : Bool := false
  /-- Declaration body layout (`declaration-body`), default `next-line`. -/
  declarationBody : DeclarationBody := .nextLine
  /-- Declaration `where` layout (`declaration-where`), default `same-line`. -/
  declarationWhere : DeclarationWhere := .sameLine
  /-- Whether a trailing `,` explodes a collection literal (`magic-trailing-comma`), default
  `respect`. -/
  magicTrailingComma : MagicTrailingComma := .respect
  /-- Import header layout (`import-layout`), default `grouped`. -/
  importLayout : Imports.ImportLayout := .grouped
  /-- The ordered module-name prefixes that get their own sub-block inside an import bucket
  under the `canonical` layout (`import-groups`), default `["Lean", "Mathlib"]`; a module
  matching none of them trails in the final sub-block. A prefix `P` matches the module `P`
  itself and every `P.…`. -/
  importGroups : Array String := Imports.defaultImportGroups
  deriving BEq, Lean.ToJson, Lean.FromJson

/-- The `[format]` settings as one string, for the `configuration` component of the cache
identity. Kept beside the fields so a new `[format]` key cannot be added without a visible decision
about identity: forgetting to extend it is the bug to prevent. The phrase encoding is
length-prefixed so a phrase containing the separator cannot alias a different list. -/
def FormatConfig.identityString (format : FormatConfig) : String :=
  let phrases :=
    format.pinnedComments.foldl (init := "") fun acc phrase => acc ++ s!"\n{phrase.length}:{phrase}"
  let groups :=
    format.importGroups.foldl (init := "") fun acc grp => acc ++ s!"\n{grp.length}:{grp}"
  s!"line-width={format.lineWidth}{phrases}\ndeclaration-body={format.declarationBody}\n\
    declaration-where={format.declarationWhere}\n\
    magic-trailing-comma={format.magicTrailingComma}\n\
    import-layout={format.importLayout}{groups}\nreflow-comments={format.reflowComments}"

/-- How a cache entry's closure currency is computed (`[cache] closure`).

`artifacts` (the default) keys each closure member by its build-artifact hash: sound, and
maximal-invalidation — any rebuild, proof-only ones included, moves the key. `interface` keys a
member by the elaboration-visible interface its `leanFmtArtifact` sidecar records when one
exists (a module's own declarations' names, kinds, types, reducibility, reducible-visible
bodies), falling back to the artifact hash for members without a sidecar — dependencies, which
do not build the facet, change only on a dependency update, exactly when their interface would
move anyway. The two documented gaps: kernel `isDefEq` can unfold any definition, so a theorem's
proof-term change is downstream-visible in pathological cases; and attribute deltas on imported
declarations are extension state, outside the hash. Both price a stale hit at nonzero, which is
why the mode is opt-in and the kill switch stays. A member whose currency neither path can
establish is an ordinary miss, never a hit. -/
inductive ClosureMode where
  | artifacts
  | «interface»
  deriving BEq, Inhabited, Repr

structure FormatterConfig where private mk ::
  includePatterns : Array PathPattern
  excludePatterns : Array PathPattern
  /-- `force-exclude`: apply the ignore sources and `exclude` to **explicitly named**
  paths too, not only to discovered ones. It exists because `format`
  writes: a pre-commit hook that passes staged paths must be able to say "still
  never write these". It never re-enables the `include` list — naming a path is a statement,
  whereas `include` answers "when I name nothing, format these". -/
  forceExclude : Bool
  /-- `respect-gitignore`: honor `.gitignore`, `.ignore`, `.git/info/exclude`, and the
  global git ignore file when discovering sources. The `.lake` exclusion is *not* one of these
  sources and does not turn off with them. -/
  respectGitignore : Bool
  /-- The `[format]` section — identity-bearing (`FormatConfig`). -/
  format : FormatConfig
  /-- The `[cache]` section's `closure` key: how closure currency is computed (`ClosureMode`).
  Not part of `configurationIdentity` — the mode changes the digest *values* themselves (the
  member prefix differs), so toggling it misses every entry without an identity change. -/
  closureMode : ClosureMode
  /-- Non-fatal notices raised while **loading** this configuration: a linter key still
  spelled at the top level. They follow the same contract as
  `RulePlan.notices` — stderr, never changing exit status or which rules run — but cannot live
  there, because a `[format]` or discovery notice has no plan to hang off. The freeze named this
  widening of the channel. -/
  notices : Array String
  /-- Where each setting came from, in composition order: `(key, file, line)`. For a scalar
  or base array the **last** entry won; for an additive `extend-*` key every entry contributed,
  which is why composition preserves order and duplicates. Consumed by `config show`;
  `Lake.Toml.Value` carries a `ref : Syntax` on every constructor, so the position is recoverable
  without a second parse. -/
  origins : Array (String × String × Nat)
  selectedSelectors : Array String
  /-- `extend-select`: selectors that *add* to the chosen selection
  without replacing it, so a project extends `default` without restating it. -/
  extendSelectSelectors : Array String
  ignoredSelectors : Array String
  perFileIgnores : Array PerFileIgnore
  extendSafeFixes : Array String
  extendUnsafeFixes : Array String
  /-- The fix-selection axis, orthogonal to rule selection and to safe/unsafe:
  which rules' fixes `fix` may apply. `fixable` replaces the base (default `all`),
  `extend-fixable` adds, `unfixable` removes; resolved by the same specificity model as
  select/ignore. A selected-but-unfixable rule is still reported — only its fix is withheld. -/
  fixableSelectors : Array String
  unfixableSelectors : Array String
  extendFixableSelectors : Array String
  /-- Preview mode: with it off, `all`/`default`/category expand to stable
  rules only and an explicit preview-code selection is an error; with it on, preview rules become
  reachable. -/
  preview : Bool

structure RulePlan where private mk ::
  selected : Array String
  /-- Codes whose fixes `fix` may apply — the fix-selection axis resolved over the
  selected set (`fixable`/`unfixable`/`extend-fixable`). A selected code
  absent here is reported but its fix is withheld from the patch, as an unadmitted unsafe fix
  is. -/
  fixableSelected : Array String := #[]
  perFileIgnores : Array PerFileIgnore
  /-- Rule codes whose fixes are promoted to safe, and demoted to unsafe. Resolved from
  `extend-safe-fixes`/`extend-unsafe-fixes`; a code in both is rejected at plan construction, so
  the two arrays here are disjoint. Display-only is never in either — it is a limit configuration
  cannot lift. -/
  extendSafe : Array String
  extendUnsafe : Array String
  /-- Non-fatal notices raised while resolving selectors — a retired/reserved code named in
  a selector, or a deprecated rule selected explicitly. The IO caller
  (`Application`, `Service`) prints these to stderr; they never change exit status or which rules
  run. -/
  notices : Array String := #[]

/-- Every CLI-side selection input, bundled so `rulePlan` takes one argument instead of
seven. Each field mirrors a `--flag`; empty/false is "not given on the CLI". -/
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

private def compilePattern (anchor : String) (source : String) : Except String PathPattern := do
  let normalized := normalizePath source
  unless !normalized.isEmpty && !normalized.startsWith "/" do
    throw s!"invalid path pattern '{source}': expected a nonempty relative pattern"
  let segments := normalized.splitOn "/"
  unless segments.all validPatternSegment do
    throw
        s!"invalid path pattern '{source}': '**' must be a complete component and '.'/'..' are forbidden"
  return { source := normalized, segments, anchor }

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
  | expected :: pattern, actual :: text => expected == actual && segmentMatches pattern text
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

/-- Strip a pattern's anchor from a root-relative path, or fail when the path lies outside the
anchoring directory. A file the declaring config does not govern can never match its patterns. -/
private def stripAnchor (anchor path : String) : Option String :=
  if anchor.isEmpty then some path
  else
    let directory := anchor ++ "/"
    if path.startsWith directory then some ((path.drop directory.length).toString) else none

/-- Match a root-relative path against an anchored pattern. -/
private def PathPattern.matches (pattern : PathPattern) (path : String) : Bool :=
  match stripAnchor pattern.anchor (normalizePath path) with
  | none => false
  | some rest => pathMatches pattern.segments (rest.splitOn "/")

private def valueStrings (key : String) : Lake.Toml.Value → Except String (Array String)
  | .array _ values =>
    values.mapM fun
      | .string _ value => .ok value
      | _ => .error s!"configuration key '{key}' expects an array of strings"
  | _ => .error s!"configuration key '{key}' expects an array of strings"

private def keyString : Lean.Name → String
  | .str .anonymous value => value
  | name => name.toString

/-- A selector names a category iff some rule declares it. Categories are derived from the
full rule identity set (`allRuleInfos` = engine rules + import rules), never a hardcoded list: a
new category (`security`, `imports`) becomes selectable the moment a rule carries it, and
`expandSelector`/`selectorsValid` cannot drift apart. Reading `allRuleInfos` rather than
`ruleRegistry` keeps `--select imports` and FMT003/04/05 selectable even though those rules live
outside the linear-tier engine. -/
private def isCategory (selector : String) : Bool :=
  allRuleInfos.any (·.category == selector)

/-- A selector token is valid if it is a meta selector, a category, a live code, or a
**reserved/retired code**. Reserved codes are accepted rather than
rejected so a legacy config that still names a retired code keeps loading; it resolves to no live
rule and raises a notice at plan time (`rulePlan`). -/
private def selectorsValid (selectors : Array String) : Except String Unit := do
  for selector in selectors do
    unless
      selector == "all" || selector == "default" || isCategory selector ||
        allRuleInfos.any (·.code == selector) ||
        isReservedCode selector do
      throw s!"unknown rule selector: {selector}"

private def parsePerFileIgnores (anchor : String) (value : Lake.Toml.Value) :
    Except String (Array PerFileIgnore) := do
  let .table _ table := value | throw "configuration key 'per-file-ignores' expects a table"
  table.items.mapM fun (key, value) => do
      let pattern ← compilePattern anchor (keyString key)
      let selectors ← valueStrings s!"per-file-ignores.{key}" value
      selectorsValid selectors
      return { pattern, selectors }

/-- One configuration file's contents, before defaults and before composition with an `extend` parent.

Every base setting is an `Option` so that "absent" differs from "set to the default
value". Without that split, `extend` composition cannot tell a silent child from one that restates
the default, and the child would clobber its parent either way. The
additive `extend-*` fields are plain arrays because they concatenate rather than override, the rule
those keys already follow within a single file. -/
private structure PartialConfig where
  extend? : Option String := none
  includePatterns? : Option (Array PathPattern) := none
  excludePatterns? : Option (Array PathPattern) := none
  forceExclude? : Option Bool := none
  respectGitignore? : Option Bool := none
  preview? : Option Bool := none
  lineWidth? : Option Nat := none
  pinnedComments? : Option (Array String) := none
  reflowComments? : Option Bool := none
  declarationBody? : Option DeclarationBody := none
  declarationWhere? : Option DeclarationWhere := none
  magicTrailingComma? : Option MagicTrailingComma := none
  importLayout? : Option Imports.ImportLayout := none
  importGroups? : Option (Array String) := none
  closureMode? : Option ClosureMode := none
  selectedSelectors? : Option (Array String) := none
  ignoredSelectors? : Option (Array String) := none
  fixableSelectors? : Option (Array String) := none
  unfixableSelectors? : Option (Array String) := none
  extendSelectSelectors : Array String := #[]
  extendFixableSelectors : Array String := #[]
  extendSafeFixes : Array String := #[]
  extendUnsafeFixes : Array String := #[]
  perFileIgnores : Array PerFileIgnore := #[]
  notices : Array String := #[]
  origins : Array (String × String × Nat) := #[]

private def orParent (child parent : Option α) : Option α :=
  match child with
  | some value => some value
  | none => parent

/-- Compose a parent configuration with the child that `extend`s it.

Scalars and base arrays: the child replaces the parent whole, which is what lets a child
*narrow* a parent. The `extend-*` family concatenates parent-then-child, the same additive rule
those keys have within one file. `per-file-ignores` merges key-wise, the child winning on an
identical anchored pattern. `extend` itself is never inherited: each file names only its own
parent.

Duplicates and order survive concatenation on purpose. `resolveAxis` folds selector specificity
with `Nat.max`, so a repeated token is idempotent and neither duplicates nor order show up in the
resolved plan — but `origins` needs every contributing file to answer `config show`. -/
private def PartialConfig.compose (parent child : PartialConfig) : PartialConfig where
  extend? := none
  includePatterns? := orParent child.includePatterns? parent.includePatterns?
  excludePatterns? := orParent child.excludePatterns? parent.excludePatterns?
  forceExclude? := orParent child.forceExclude? parent.forceExclude?
  respectGitignore? := orParent child.respectGitignore? parent.respectGitignore?
  preview? := orParent child.preview? parent.preview?
  lineWidth? := orParent child.lineWidth? parent.lineWidth?
  reflowComments? := orParent child.reflowComments? parent.reflowComments?
  pinnedComments? := orParent child.pinnedComments? parent.pinnedComments?
  declarationBody? := orParent child.declarationBody? parent.declarationBody?
  declarationWhere? := orParent child.declarationWhere? parent.declarationWhere?
  magicTrailingComma? := orParent child.magicTrailingComma? parent.magicTrailingComma?
  importLayout? := orParent child.importLayout? parent.importLayout?
  importGroups? := orParent child.importGroups? parent.importGroups?
  selectedSelectors? := orParent child.selectedSelectors? parent.selectedSelectors?
  ignoredSelectors? := orParent child.ignoredSelectors? parent.ignoredSelectors?
  fixableSelectors? := orParent child.fixableSelectors? parent.fixableSelectors?
  unfixableSelectors? := orParent child.unfixableSelectors? parent.unfixableSelectors?
  extendSelectSelectors := parent.extendSelectSelectors ++ child.extendSelectSelectors
  extendFixableSelectors := parent.extendFixableSelectors ++ child.extendFixableSelectors
  extendSafeFixes := parent.extendSafeFixes ++ child.extendSafeFixes
  extendUnsafeFixes := parent.extendUnsafeFixes ++ child.extendUnsafeFixes
  perFileIgnores :=
    (parent.perFileIgnores.filter fun entry =>
        !child.perFileIgnores.any fun other =>
            other.pattern.source == entry.pattern.source &&
              other.pattern.anchor == entry.pattern.anchor) ++
      child.perFileIgnores
  notices := parent.notices ++ child.notices
  origins := parent.origins ++ child.origins

/-- Apply defaults and validate. Selector validation happens here rather than per file so
that a composed chain is checked once, in its resolved form. -/
private def PartialConfig.resolve (config : PartialConfig) : Except String FormatterConfig := do
  let selectedSelectors := config.selectedSelectors?.getD #["default"]
  let ignoredSelectors := config.ignoredSelectors?.getD #[]
  let fixableSelectors := config.fixableSelectors?.getD #[]
  let unfixableSelectors := config.unfixableSelectors?.getD #[]
  selectorsValid selectedSelectors
  selectorsValid config.extendSelectSelectors
  selectorsValid ignoredSelectors
  selectorsValid config.extendSafeFixes
  selectorsValid config.extendUnsafeFixes
  selectorsValid fixableSelectors
  selectorsValid unfixableSelectors
  selectorsValid config.extendFixableSelectors
  return {
      includePatterns := config.includePatterns?.getD #[]
      excludePatterns := config.excludePatterns?.getD #[]
      forceExclude := config.forceExclude?.getD false
      respectGitignore := config.respectGitignore?.getD true
      format :=
        { lineWidth := config.lineWidth?.getD 100
          pinnedComments := config.pinnedComments?.getD #["shake: keep"]
          reflowComments := config.reflowComments?.getD false
          declarationBody := config.declarationBody?.getD .nextLine
          declarationWhere := config.declarationWhere?.getD .sameLine
          magicTrailingComma := config.magicTrailingComma?.getD .respect
          importLayout := config.importLayout?.getD .grouped
          importGroups := config.importGroups?.getD Imports.defaultImportGroups }
      closureMode := config.closureMode?.getD .artifacts
      notices := config.notices
      origins := config.origins
      selectedSelectors := selectedSelectors
      extendSelectSelectors := config.extendSelectSelectors
      ignoredSelectors := ignoredSelectors
      perFileIgnores := config.perFileIgnores
      extendSafeFixes := config.extendSafeFixes
      extendUnsafeFixes := config.extendUnsafeFixes
      fixableSelectors := fixableSelectors
      unfixableSelectors := unfixableSelectors
      extendFixableSelectors := config.extendFixableSelectors
      preview := config.preview?.getD false }

private def defaultConfig : FormatterConfig :=
  { includePatterns := #[]
    excludePatterns := #[]
    forceExclude := false
    respectGitignore := true
    format := { }
    closureMode := .artifacts
    notices := #[]
    origins := #[]
    selectedSelectors := #["default"]
    extendSelectSelectors := #[]
    ignoredSelectors := #[]
    perFileIgnores := #[]
    extendSafeFixes := #[]
    extendUnsafeFixes := #[]
    fixableSelectors := #[]
    unfixableSelectors := #[]
    extendFixableSelectors := #[]
    preview := false }

/-- The `[lint]` keys, which are also still accepted at the top level for migration. -/
private def lintKeys : Array String :=
  #["select", "extend-select", "ignore", "per-file-ignores", "extend-safe-fixes",
    "extend-unsafe-fixes", "fixable", "unfixable", "extend-fixable"]

/-- The line a TOML value sits on, for provenance (`config show`) and error messages.
Every `Lake.Toml.Value` constructor carries a `ref : Syntax`, so the position of the value that won
is recoverable without parsing the file a second time. -/
private def valueLine (fileMap : Lean.FileMap) (value : Lake.Toml.Value) : Nat :=
  match value.ref.getPos? with
  | some pos => (fileMap.toPosition pos).line
  | none => 0

/-- Assign one `[lint]` key into a partial configuration. Shared by the `[lint]` section
and by the deprecated top-level spelling, so the two cannot drift in meaning — only in provenance
and notices. -/
private def assignLintKey (anchor file : String) (fileMap : Lean.FileMap) (config : PartialConfig)
    (key : String) (value : Lake.Toml.Value) : Except String PartialConfig := do
  let origins := config.origins.push (key, file, valueLine fileMap value)
  match key with
  | "select" =>
    return { config with
        selectedSelectors? := ← valueStrings key value, origins }
  | "ignore" =>
    return { config with
        ignoredSelectors? := ← valueStrings key value, origins }
  | "fixable" =>
    return { config with
        fixableSelectors? := ← valueStrings key value, origins }
  | "unfixable" =>
    return { config with
        unfixableSelectors? := ← valueStrings key value, origins }
  | "extend-select" =>
    return { config with
        extendSelectSelectors := config.extendSelectSelectors ++ (← valueStrings key value),
        origins }
  | "extend-fixable" =>
    return { config with
        extendFixableSelectors := config.extendFixableSelectors ++ (← valueStrings key value),
        origins }
  | "extend-safe-fixes" =>
    return { config with
        extendSafeFixes := config.extendSafeFixes ++ (← valueStrings key value), origins }
  | "extend-unsafe-fixes" =>
    return { config with
        extendUnsafeFixes := config.extendUnsafeFixes ++ (← valueStrings key value), origins }
  | "per-file-ignores" =>
    return { config with
        perFileIgnores := config.perFileIgnores ++ (← parsePerFileIgnores anchor value), origins }
  | _ =>
    throw s!"unknown configuration key: {key}"

/-- Parse one configuration file into its pre-composition form.

`anchor` is the directory this file's path patterns are anchored at, relative to the project root;
`file` is its displayed path, used for provenance and diagnostics. -/
private def parseFile (anchor file : String) (fileMap : Lean.FileMap) (table : Lake.Toml.Table) :
    Except String PartialConfig := do
  -- Split the document before interpreting it: a key's *section* decides whether it is
  -- identity-bearing, and the both-set check needs the two key sets in hand at once.
  let mut topLevel : Array (String × Lake.Toml.Value) := #[]
  let mut formatSection : Array (String × Lake.Toml.Value) := #[]
  let mut lintSection : Array (String × Lake.Toml.Value) := #[]
  let mut cacheSection : Array (String × Lake.Toml.Value) := #[]
  for (key, value) in table.items do
    match keyString key with
    | "format" =>
      let .table _ entries := value | throw "configuration section '[format]' expects a table"
      formatSection := entries.items.map fun (key, value) => (keyString key, value)
    | "lint" =>
      let .table _ entries := value | throw "configuration section '[lint]' expects a table"
      lintSection := entries.items.map fun (key, value) => (keyString key, value)
    | "cache" =>
      let .table _ entries := value | throw "configuration section '[cache]' expects a table"
      cacheSection := entries.items.map fun (key, value) => (keyString key, value)
    | other =>
      topLevel := topLevel.push (other, value)
  -- A key set in both places is a contradiction the user can resolve in one edit, so it
  -- does not resolve itself (as with `extend-safe-fixes` ∩ `extend-unsafe-fixes` below).
  for (key, _) in topLevel do
    if lintSection.any (·.1 == key) then
      throw s!"configuration key '{key}' is set both at the top level and in [lint]"
  let mut config : PartialConfig := { }
  -- Deprecated flat spelling first, so an `extend-*` key set in both a flat parent and a
  -- sectioned child still concatenates in document order.
  for (key, value) in topLevel do
    if lintKeys.contains key then
      config ← assignLintKey anchor file fileMap config key value
      let notice :=
        s!"{file}: configuration key '{key}' at the top level is deprecated; move it into [lint]"
      config := { config with notices := config.notices.push notice }
    else
      let origins := config.origins.push (key, file, valueLine fileMap value)
      match key with
      | "extend" =>
        let .string _ target := value | throw "configuration key 'extend' expects a string"
        config :=
          { config with
            extend? := some target, origins }
      | "include" =>
        let sources ← valueStrings "include" value
        config :=
          { config with
            includePatterns? := ← sources.mapM (compilePattern anchor), origins }
      | "exclude" =>
        let sources ← valueStrings "exclude" value
        config :=
          { config with
            excludePatterns? := ← sources.mapM (compilePattern anchor), origins }
      | "force-exclude" =>
        let .boolean _ flag := value | throw "configuration key 'force-exclude' expects a boolean"
        config :=
          { config with
            forceExclude? := some flag, origins }
      | "respect-gitignore" =>
        let .boolean _ flag :=
          value | throw "configuration key 'respect-gitignore' expects a boolean"
        config :=
          { config with
            respectGitignore? := some flag, origins }
      | "preview" =>
        let .boolean _ flag := value | throw "configuration key 'preview' expects a boolean"
        config :=
          { config with
            preview? := some flag, origins }
      -- These `[format]` keys are new, so they have no legacy spelling to protect: a top-level
      -- use is an error rather than a notice, so the keys never acquire an ambiguous section.
      | "line-width" | "pinned-comments" | "reflow-comments" | "declaration-body" |
        "declaration-where" | "magic-trailing-comma" | "import-layout" | "import-groups" =>
        throw s!"configuration key '{key}' belongs in the [format] section"
      -- Same treatment as the `[format]` keys above: one spelling, one section, no ambiguity.
      | "closure" =>
        throw s!"configuration key '{key}' belongs in the [cache] section"
      | unknown =>
        throw s!"unknown configuration key: {unknown}"
  for (key, value) in formatSection do
    let origins := config.origins.push (s!"format.{key}", file, valueLine fileMap value)
    match key with
    | "line-width" =>
      let .integer _ width := value | throw "configuration key 'line-width' expects an integer"
      unless 1 ≤ width && width ≤ 1000 do
        throw s!"configuration key 'line-width' expects an integer between 1 and 1000, got {width}"
      config :=
        { config with
          lineWidth? := some width.toNat, origins }
    | "pinned-comments" =>
      let phrases ← valueStrings "pinned-comments" value
      if phrases.any String.isEmpty then
        throw "configuration key 'pinned-comments' expects non-empty strings"
      config :=
        { config with
          pinnedComments? := some phrases, origins }
    | "reflow-comments" =>
      let .boolean _ flag := value | throw "configuration key 'reflow-comments' expects a boolean"
      config :=
        { config with
          reflowComments? := some flag, origins }
    | "declaration-body" =>
      let .string _ body := value | throw "configuration key 'declaration-body' expects a string"
      let declarationBody ←
        match body with
        | "next-line" =>
          pure DeclarationBody.nextLine
        | "same-line" =>
          pure DeclarationBody.sameLine
        | other =>
          throw
              s!"configuration key 'declaration-body' expects \"next-line\" or \
          \"same-line\", got \"{other}\""
      config :=
        { config with
          declarationBody? := some declarationBody, origins }
    | "declaration-where" =>
      let .string _ form := value | throw "configuration key 'declaration-where' expects a string"
      let declarationWhere ←
        match form with
        | "same-line" =>
          pure DeclarationWhere.sameLine
        | "next-line" =>
          pure DeclarationWhere.nextLine
        | other =>
          throw
              s!"configuration key 'declaration-where' expects \"same-line\" or \
          \"next-line\", got \"{other}\""
      config :=
        { config with
          declarationWhere? := some declarationWhere, origins }
    | "magic-trailing-comma" =>
      let .string _ trailing := value
        | throw "configuration key 'magic-trailing-comma' expects a string"
      let magicTrailingComma ←
        match trailing with
        | "respect" =>
          pure MagicTrailingComma.respect
        | "ignore" =>
          pure MagicTrailingComma.ignore
        | other =>
          throw
              s!"configuration key 'magic-trailing-comma' expects \"respect\" or \
          \"ignore\", got \"{other}\""
      config :=
        { config with
          magicTrailingComma? := some magicTrailingComma, origins }
    | "import-layout" =>
      let .string _ layout := value | throw "configuration key 'import-layout' expects a string"
      let importLayout ←
        match layout with
        | "grouped" =>
          pure Imports.ImportLayout.grouped
        | "canonical" =>
          pure Imports.ImportLayout.canonical
        | other =>
          throw
              s!"configuration key 'import-layout' expects \"grouped\" or \
          \"canonical\", got \"{other}\""
      config :=
        { config with
          importLayout? := some importLayout, origins }
    | "import-groups" =>
      let prefixes ← valueStrings "import-groups" value
      if prefixes.any (fun grp => grp.isEmpty || grp.any Char.isWhitespace) then
        throw "configuration key 'import-groups' expects non-empty whitespace-free module prefixes"
      config :=
        { config with
          importGroups? := some prefixes, origins }
    | unknown =>
      throw s!"unknown configuration key: format.{unknown}"
  for (key, value) in cacheSection do
    let origins := config.origins.push (s!"cache.{key}", file, valueLine fileMap value)
    match key with
    | "closure" =>
      let .string _ mode := value | throw "configuration key 'closure' expects a string"
      let closureMode ←
        match mode with
        | "artifacts" =>
          pure ClosureMode.artifacts
        | "interface" =>
          pure ClosureMode.«interface»
        | other =>
          throw
              s!"configuration key 'closure' expects \"artifacts\" or \"interface\", \
          got \"{other}\""
      config :=
        { config with
          closureMode? := some closureMode, origins }
    | unknown =>
      throw s!"unknown configuration key: cache.{unknown}"
  for (key, value) in lintSection do
    unless lintKeys.contains key do
      throw s!"unknown configuration key: lint.{key}"
    config ← assignLintKey anchor file fileMap config key value
  return config

private def loadDocument (path : System.FilePath) : IO (Lake.Toml.Table × Lean.FileMap) := do
  let input ← IO.FS.readFile path
  let context := Lean.Parser.mkInputContext input path.toString
  match ← Lake.Toml.loadToml context |>.toBaseIO with
  | .ok table =>
    return (table, context.fileMap)
  | .error messages =>
    let rendered ← messages.toArray.mapM (·.toString)
    throw <|
        IO.userError
          s!"invalid formatter configuration {path}: \
      {String.intercalate "; " rendered.toList}"

/-- The directory a config file's patterns anchor at, relative to `root`, or `none` when the
file lies outside the project entirely. -/
def anchorFor (root directory : System.FilePath) : IO (Option String) := do
  let root ← IO.FS.realPath root
  let directory ← IO.FS.realPath directory
  if directory == root then
    return some ""
  let rootPrefix := root.toString ++ System.FilePath.pathSeparator.toString
  let text := directory.toString
  if text.startsWith rootPrefix then
    return some (normalizePath ((text.drop rootPrefix.length).toString))
  return none

/-- The maximum `extend` chain length. Cycle detection alone terminates, so this is a
resource bound, not a correctness one. -/
private def maxExtendDepth : Nat :=
  32

/-- Load one configuration file and every ancestor it `extend`s, composing parent-first.

Chain members are identified by **realpath**, so a symlinked alias of an ancestor is
still caught as a cycle. A parent outside the project root keeps the extending file's anchor rather
than acquiring one outside the tree, which is what makes an out-of-tree shared config usable at
all; a parent inside the root anchors at its own directory like any discovered config. -/
private partial def loadChain (root : System.FilePath) (path : System.FilePath) (anchor : String)
    (seen : Array System.FilePath) : IO PartialConfig := do
  let resolved ← IO.FS.realPath path
  if seen.contains resolved then
    let cycle := (seen.push resolved).map (·.toString)
    throw <| IO.userError s!"configuration extend cycle: {String.intercalate " -> " cycle.toList}"
  if seen.size ≥ maxExtendDepth then
    throw <| IO.userError s!"configuration extend chain exceeds {maxExtendDepth} files: {resolved}"
  let (table, fileMap) ← loadDocument resolved
  let child ←
    match parseFile anchor resolved.toString fileMap table with
    | .ok config =>
      pure config
    | .error message =>
      throw <| IO.userError s!"invalid formatter configuration {resolved}: {message}"
  match child.extend? with
  | none =>
    return child
  | some target =>
    let directory := resolved.parent.getD root
    let targetPath :=
      if (System.FilePath.mk target).isAbsolute then System.FilePath.mk target
      else directory / target
    unless ← targetPath.pathExists do
      -- Name the path as written, beside the file that wrote it: the caller's own
      -- argument, per the `CLAUDE.md` path-error rule.
      throw <|
          IO.userError
            s!"configuration extend target does not exist: {target} (extended by {resolved})"
    let parentAnchor := (← anchorFor root (targetPath.parent.getD root)).getD anchor
    let parent ← loadChain root targetPath parentAnchor (seen.push resolved)
    return parent.compose child

/-- Load the configuration rooted at one file, following its `extend` chain. -/
def FormatterConfig.loadFrom (root : System.FilePath) (path : System.FilePath) (anchor : String) :
    IO FormatterConfig := do
  match (← loadChain root path anchor #[]).resolve with
  | .ok config =>
    return config
  | .error message =>
    throw <| IO.userError s!"invalid formatter configuration {path}: {message}"

/-- The configuration file names this product recognizes, in descending priority. -/
def recognizedConfigNames : Array String :=
  #[".lean-fmt.toml", "lean-fmt.toml"]

/-- The recognized configuration file in one directory, or `none`. Both names present is a
hard error naming both paths rather than a silent priority win — the same reasoning as every other
configuration contradiction here. -/
def recognizedConfigIn? (directory : System.FilePath) : IO (Option System.FilePath) := do
  let present : Array String ←
    recognizedConfigNames.filterM fun name => (directory / name).pathExists
  match present.toList with
  | [] =>
    return none
  | [name] =>
    return some (directory / name)
  | names =>
    throw <|
        IO.userError
          s!"directory {directory} has more than one formatter configuration: \
      {String.intercalate ", " names}"

/-- Load all formatter policy in one step. An explicit path must exist; an absent conventional
configuration is the default policy rather than an error.

An explicit `--config` anchors its path patterns at the **project root**, not at its own
directory: it is a run-wide override rather than a config that governs the subtree it sits in, and
anchoring it at its own directory would make `include`/`exclude` in a config outside the tree match
nothing. A *discovered* config anchors at its own directory. -/
def FormatterConfig.load (root : System.FilePath) (explicit? : Option System.FilePath := none) :
    IO FormatterConfig := do
  match explicit? with
  | some path =>
    unless ← path.pathExists do
      throw <| IO.userError s!"formatter configuration does not exist: {path}"
    FormatterConfig.loadFrom root path ""
  | none =>
    match ← recognizedConfigIn? root with
    | none =>
      return defaultConfig
    | some path =>
      FormatterConfig.loadFrom root path ""

/-- The `file:line` origins recorded for one key, in composition order. Empty when the
setting was never written and the default applies. -/
private def FormatterConfig.originsOf (config : FormatterConfig) (key : String) : Array String :=
  config.origins.filterMap fun (recorded, file, line) =>
    if recorded == key then some s!"{file}:{line}" else none

private def renderStrings (values : Array String) : String :=
  "[" ++ String.intercalate ", " (values.toList.map fun value => "\"" ++ value ++ "\"") ++ "]"

private def renderPatterns (patterns : Array PathPattern) : String :=
  renderStrings
    (patterns.map fun pattern =>
      if pattern.anchor.isEmpty then pattern.source else pattern.anchor ++ "/" ++ pattern.source)

/-- Every effective setting as `(key, rendered value, origin)`, in schema order — the payload
`config show` presents.

Origin is `default` when nothing wrote the setting, otherwise `file:line`. A setting
written by several files in one `extend` chain lists **every** contributing origin for the additive
`extend-*` keys and the winning one for the rest, which is why composition preserves order and
duplicates.

This lives here rather than in the CLI because `PathPattern` is private to this module: only code
that can see the anchor can render a pattern's anchored form, and leaking the type to a presenter
would be the wrong trade. -/
def FormatterConfig.describe (config : FormatterConfig) : Array (String × String × String) :=
  let winner := fun (key : String) =>
    match (config.originsOf key).back? with
    | some origin => origin
    | none => "default"
  let all := fun (key : String) =>
    let origins := config.originsOf key
    if origins.isEmpty then "default" else String.intercalate ", " origins.toList
  #[("include", renderPatterns config.includePatterns, winner "include"),
    ("exclude", renderPatterns config.excludePatterns, winner "exclude"),
    ("force-exclude", toString config.forceExclude, winner "force-exclude"),
    ("respect-gitignore", toString config.respectGitignore, winner "respect-gitignore"),
    ("preview", toString config.preview, winner "preview"),
    ("format.line-width", toString config.format.lineWidth, winner "format.line-width"),
    ("format.pinned-comments", renderStrings config.format.pinnedComments,
      winner "format.pinned-comments"),
    ("format.reflow-comments", toString config.format.reflowComments,
      winner "format.reflow-comments"),
    ("format.declaration-body", toString config.format.declarationBody,
      winner "format.declaration-body"),
    ("format.declaration-where", toString config.format.declarationWhere,
      winner "format.declaration-where"),
    ("format.magic-trailing-comma", toString config.format.magicTrailingComma,
      winner "format.magic-trailing-comma"),
    ("lint.select", renderStrings config.selectedSelectors, winner "select"),
    ("lint.extend-select", renderStrings config.extendSelectSelectors, all "extend-select"),
    ("lint.ignore", renderStrings config.ignoredSelectors, winner "ignore"),
    ("lint.fixable", renderStrings config.fixableSelectors, winner "fixable"),
    ("lint.unfixable", renderStrings config.unfixableSelectors, winner "unfixable"),
    ("lint.extend-fixable", renderStrings config.extendFixableSelectors, all "extend-fixable"),
    ("lint.extend-safe-fixes", renderStrings config.extendSafeFixes, all "extend-safe-fixes"),
    ("lint.extend-unsafe-fixes", renderStrings config.extendUnsafeFixes, all "extend-unsafe-fixes"),
    ("lint.per-file-ignores", renderStrings (config.perFileIgnores.map (·.pattern.source)),
      all "per-file-ignores")]

/-- The configuration files that contributed to this value, in composition order: the
`extend` chain plus the file that started it. Derived from `origins`, so a file that set nothing
contributes nothing — which is the honest answer for provenance. -/
def FormatterConfig.contributingFiles (config : FormatterConfig) : Array String :=
  config.origins.foldl (init := #[]) fun files (_, file, _) =>
    if files.contains file then files else files.push file

/-- Whether a discovered root-package module survives configured path selection. Empty
`include` means every root module; excludes always win. Explicit CLI files bypass this
predicate. -/
def FormatterConfig.includesPath (config : FormatterConfig) (path : String) : Bool :=
  (config.includePatterns.isEmpty || config.includePatterns.any (·.matches path)) &&
    !config.excludePatterns.any (·.matches path)

/-- Expand a selector to the codes it names, for the **subtractive** contexts
(per-file-ignores and `extend-safe/unsafe-fixes`) that project a set of codes and test containment.
`all`/`default`/category follow `defaultEnabled`/category; a bare code (live or reserved) is
itself. These contexts never need the preview gate or specificity — they only remove or reclassify
— so they keep the flat expansion. Positive selection (`select`/`ignore`/`fixable`) instead goes
through `resolveAxis`. -/
private def expandSelector (selector : String) : Array String :=
  if selector == "all" then allRuleInfos.map (·.code)
  else
    if selector == "default" then allRuleInfos.filter (·.defaultEnabled) |>.map (·.code)
    else
      if isCategory selector then allRuleInfos.filter (·.category == selector) |>.map (·.code)
      else #[selector]

private def expandSelectors (selectors : Array String) : Array String :=
  selectors.foldl (init := #[]) fun codes selector =>
    (expandSelector selector).foldl (init := codes) fun codes code =>
      if codes.contains code then codes else codes.push code

/-- The specificity of a selector token: an exact code (3) is
more specific than a category (2), which is more specific than `all`/`default` (1). A reserved code
or unrecognized token has specificity 0 and mentions no live rule. -/
private def selectorSpecificity (selector : String) : Nat :=
  if selector == "all" || selector == "default" then 1
  else if isCategory selector then 2 else if allRuleInfos.any (·.code == selector) then 3 else 0

/-- Whether `selector` names live rule `info`, honoring the **preview gate**: `all`
and a category expand to stable rules only unless `preview` is on (then their preview rules too);
`default` follows `defaultEnabled` (only stable rules are default-on); a deprecated rule is reached
only by its exact code; an exact-code selector names only its own code. -/
private def selectorMentions (preview : Bool) (selector : String) (info : RuleInfo) : Bool :=
  let gated := info.lifecycle == .stable || (info.lifecycle == .preview && preview)
  if selector == "all" then gated
  else
    if selector == "default" then info.defaultEnabled
    else if isCategory selector then info.category == selector && gated else selector == info.code

/-- Resolve one selection axis over `universe` by specificity: a rule is enabled
iff some `enable` selector names it and **strictly outranks** every `disable` selector that names
it — a tie goes to the disabler ("ignore wins"). `preview` gates what `all`/category mention. -/
private def resolveAxis (pool : Array RuleInfo) (preview : Bool) (enable disable : Array String) :
    Array String :=
  let best := fun (tokens : Array String) (info : RuleInfo) =>
    tokens.foldl (init := 0) fun acc t =>
      if selectorMentions preview t info then Nat.max acc (selectorSpecificity t) else acc
  pool.filterMap fun info =>
    let e := best enable info
    let d := best disable info
    if e > 0 && e > d then some info.code else none

/-- Resolve CLI/config selection into a `RulePlan`. A
nonempty CLI `--select` replaces configured `select` and its configured ignores; `extend-select`
always adds; ignores within the chosen layer always apply. Resolution is by specificity
(`resolveAxis`), not flat subtraction: `--select FMT008 --ignore redundancy` keeps FMT008, because
an exact selector outranks a category. The preview gate errors on an explicit preview-code
selection when preview is off, and raises a non-fatal notice for a reserved/retired or deprecated
code named in a selector. -/
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
  -- Preview gate: an explicit exact-code selection of a preview rule is an error unless
  -- preview is on — a specific message, never a silent drop. A category/`all` simply omits preview
  -- rules when off.
  for t in enableTokens do
    if let some info := allRuleInfos.find? (·.code == t) then
      if info.lifecycle == .preview && !preview then
        throw s!"rule {t} is in preview; enable preview mode (--preview) to select it"
  -- Non-fatal notices: a reserved/retired code, or a deprecated rule, named in any
  -- selector.
  let mut notices := #[]
  for t in enableTokens ++ ignoreTokens do
    if isReservedCode t then
      notices :=
        notices.push
          s!"selector {t} names no live rule ({(reservedDisposition? t).getD "reserved code"})"
    else if let some info := allRuleInfos.find? (·.code == t) then
      if info.lifecycle == .deprecated then
        let migration :=
          match info.replacement? with
          | some r => s!"; use {r} instead"
          | none => ""
        notices := notices.push s!"rule {t} is deprecated{migration}"
  let selected := resolveAxis allRuleInfos preview enableTokens ignoreTokens
  -- Fix-selection axis, resolved over the *selected* set (already preview-gated, so
  -- mention with `preview := true`). Base is `all` unless `fixable` is configured;
  -- `extend-fixable` adds, `unfixable` removes. A selected-but-unfixable code stays reported; only
  -- its fix is withheld (`prepareFile`).
  let fixableOwns := !cli.fixable.isEmpty
  let fixEnable :=
    (if fixableOwns then cli.fixable
      else if config.fixableSelectors.isEmpty then #["all"] else config.fixableSelectors) ++
      config.extendFixableSelectors ++
      cli.extendFixable
  let fixDisable := (if fixableOwns then #[] else config.unfixableSelectors) ++ cli.unfixable
  let selectedInfos := allRuleInfos.filter (selected.contains ·.code)
  let fixableSelected := resolveAxis selectedInfos true fixEnable fixDisable
  -- Reclassification is config-only; there is no CLI spelling, so it is resolved once here
  -- from the config's own lists. A rule in both is a contradiction, not last-writer-wins.
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
      notices }

/-- Apply a command-line `reflow-comments` override to one resolved configuration: the flag wins
over every file, `--config` included -- naming it on the command line is a statement about this
run. -/
def FormatterConfig.overrideReflowComments (config : FormatterConfig) (flag : Bool) :
    FormatterConfig :=
  { config with format := { config.format with reflowComments := flag } }

private def ignoredForPath (plan : RulePlan) (path code : String) : Bool :=
  plan.perFileIgnores.any fun entry =>
    entry.pattern.matches path && (expandSelectors entry.selectors).contains code

/-- The effective applicability of `code`'s fix, after per-rule reclassification. No
promotion lifts display-only; otherwise `extend-safe-fixes` promotes and `extend-unsafe-fixes`
demotes. The two lists are disjoint (checked at plan construction), so the order of these tests
does not matter.

A projection, never read by a rule: like selection, reclassification lives in the plan so that
turning a fix safe cannot re-elaborate anything and a rule cannot decide its own admission. -/
def RulePlan.effectiveApplicability (plan : RulePlan) (code : String) (base : Applicability) :
    Applicability :=
  match base with
  | .displayOnly => .displayOnly
  | _ =>
    if plan.extendSafe.contains code then .safe
    else if plan.extendUnsafe.contains code then .unsafe else base

/-- Project canonical findings onto this plan: keep the selected, non-per-file-ignored
ones, and rewrite each surviving fix's applicability to its effective value. The reported findings
therefore carry the applicability a user will act on; admission (which of them `fix` applies) is a
separate, downstream decision (`Applicability.admitted`). -/
def RulePlan.findings (plan : RulePlan) (path : String) (findings : Array Finding) :
    Array Finding :=
  (findings.filter fun finding =>
        plan.selected.contains finding.code && !ignoredForPath plan path finding.code).map
    fun finding =>
    match finding.fix? with
    | some fix =>
        let applicability := plan.effectiveApplicability finding.code fix.applicability
        { finding with fix? := some { fix with applicability } }
    | none => finding

def RulePlan.activeCount (plan : RulePlan) : Nat :=
  plan.selected.size

/-- The cheapest facts that can answer every selected rule of `rules`.

Selection derives what a run must *obtain*,
and nothing else. It does not decide a worker, an artifact strategy, a cache identity, or an order
— a run that selects nothing costs `source`, and turning a rule on can never rebuild or
re-elaborate anything.

The mode contributes separately (`RunMode.rendersCanonical`): a rendering mode needs the projection
whatever its rules need.

`rules` is a parameter for the same reason `runRulesOf` takes one, and must stay in step with it:
the two derive from one array or they can disagree about what a selection costs. Only tests pass
their own; every production caller goes through `requiredTier`. -/
def RulePlan.requiredTierOf (plan : RulePlan) (rules : Array Rule) : Tier :=
  rules.foldl (init := .source) fun tier rule =>
    if plan.selected.contains rule.code then tier.max rule.tier else tier

/-- The cheapest facts that can answer every selected rule the product ships. -/
def RulePlan.requiredTier (plan : RulePlan) : Tier :=
  plan.requiredTierOf ruleRegistry

/-- The tier selected rules require. Formatting is an exact-frontend demand, not a semantic fact. -/
def RulePlan.demandedTier (plan : RulePlan) : Tier :=
  plan.requiredTier

/-- Whether the plan selects a rule whose fix reads the owned deprecation-occurrence
fact. Governs the `occurrences` capability and the info-tree fold's cost
(`RuleInfo.needsOccurrences`). `rules` is a parameter for the same reason `requiredTierOf` takes
one — capture cost and rule execution derive from one registry or they disagree about what a
selection costs. -/
def RulePlan.selectsOccurrenceRuleOf (plan : RulePlan) (rules : Array Rule) : Bool :=
  rules.any fun rule => plan.selected.contains rule.code && rule.info.needsOccurrences

def RulePlan.selectsOccurrenceRule (plan : RulePlan) : Bool :=
  plan.selectsOccurrenceRuleOf ruleRegistry

/-- The semantic rule sub-fact a run demands beyond the semantic tier itself:
`occurrences` when a run that **applies** fixes selects an occurrence-fix rule (FMT012's rename) —
the one capability that gates the whole-file info-tree fold.

The `occurrences` demand keys off `applies` (true only for `fix`). A check does not pay the fold.
`analysisServes` serves a `.semantic` entry only when `demandedCaps.subset entry.caps`, so a fix's
`occurrences` demand misses a report-only check entry that never captured it. -/
def RulePlan.demandedCaps (plan : RulePlan) (applies : Bool) : SemanticCaps :=
  if plan.demandedTier == .semantic then { occurrences := applies && plan.selectsOccurrenceRule }
  else { }

end LeanFmt.Internal
