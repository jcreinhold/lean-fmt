module

import all LeanFmt.Config

open System

namespace LeanFmt.Internal.Discovery

/-! # Hierarchical configuration discovery and ignore sources

The private capability `ruff-13` RCD-IMPL owes: one filesystem walk that simultaneously collects
candidate sources, recognized configuration files, and ignore files, so that resolving one file's
effective configuration is an **in-memory** ascent rather than a walk of its own
(`notes/01-discovery.md` §4.2).

Nothing here interprets project semantics. Executable Lake configuration remains separately evaluated
by `Project.loadWorkspace`; this module reads TOML policy and ignore files and nothing else.
-/

/-! ## Git ignore patterns

Deliberately **not** `Config.PathPattern`. That type is what `include`/`exclude` have always meant
(segment-wise, no anchoring, no negation) and changing it would silently reinterpret every existing
config. Git ignore *sources* are where users already expect git semantics, so they get a matcher that
implements them (`notes/01-discovery.md` §7, §10). -/

private structure IgnorePattern where
  /-- Pattern components, `/`-separated. A non-anchored pattern is stored with a leading `**`, which
  is exactly git's "a pattern with no slash matches at any depth". -/
  segments : List String
  /-- A `!` prefix: re-includes a path an earlier pattern excluded. -/
  negated : Bool
  /-- A trailing `/`: matches directories only. -/
  directoryOnly : Bool
  /-- The directory containing the ignore file, relative to the project root (`""` is the root). -/
  base : String
  source : String

/-- Match one character class, `[abc]`, `[a-z]`, `[!abc]`/`[^abc]`. Returns the matched-ness and the
remainder of the pattern after the closing `]`; an unterminated class is treated as a literal `[`,
which is what git does. -/
private def matchClass (pattern : List Char) (actual : Char) : Option (Bool × List Char) :=
  let (negated, pattern) := match pattern with
    | '!' :: rest => (true, rest)
    | '^' :: rest => (true, rest)
    | rest => (false, rest)
  let rec go (pattern : List Char) (hit : Bool) : Option (Bool × List Char) :=
    match pattern with
    | [] => none
    | ']' :: rest => some (hit != negated, rest)
    | low :: '-' :: high :: rest =>
      if high == ']' then go ('-' :: high :: rest) (hit || actual == low)
      else go rest (hit || (low ≤ actual && actual ≤ high))
    | c :: rest => go rest (hit || actual == c)
  go pattern false

/-- Glob one path component. `*` and `?` never cross `/`, which is why this runs per component. -/
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
  | '[' :: pattern, actual :: text =>
    match matchClass pattern actual with
    | some (true, rest) => segmentMatches rest text
    | some (false, _) => false
    | none => actual == '[' && segmentMatches pattern text
  | '\\' :: expected :: pattern, actual :: text =>
    expected == actual && segmentMatches pattern text
  | expected :: pattern, actual :: text =>
    expected == actual && segmentMatches pattern text
  | _ :: _, [] => false

/-- Match a component list against a pattern component list, where `**` crosses `/`. -/
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

/-- A pattern matches a *prefix* of the path when it names an ancestor directory. Git's rule that an
excluded directory cannot have its contents re-included is what makes this the right test: once a
directory matches, everything beneath it is excluded, so a directory-only pattern must match a file
by matching one of its ancestors. -/
private partial def prefixMatches (pattern path : List String) : Bool :=
  match path with
  | [] => false
  | _ =>
    pathMatches pattern path ||
      prefixMatches pattern (path.dropLast)

private def compileIgnoreLine (base line : String) : Option IgnorePattern :=
  let trimmed := line.trimAscii.toString
  if trimmed.isEmpty || trimmed.startsWith "#" then none
  else
    let (negated, body) :=
      if trimmed.startsWith "!" then (true, (trimmed.drop 1).toString) else (false, trimmed)
    let (directoryOnly, body) :=
      if body.endsWith "/" then (true, (body.dropEnd 1).toString) else (false, body)
    if body.isEmpty then none
    else
      -- A leading `/` anchors to the ignore file's own directory; a slash anywhere else also anchors
      -- (git's rule). Otherwise the pattern matches at any depth, spelled here as a leading `**`.
      let anchored := body.startsWith "/" || (body.dropEnd 1).contains '/'
      let body := if body.startsWith "/" then (body.drop 1).toString else body
      let segments := body.splitOn "/"
      let segments := if anchored then segments else "**" :: segments
      some { segments, negated, directoryOnly, base, source := trimmed }

private def IgnorePattern.matches (pattern : IgnorePattern) (path : String) (isDirectory : Bool) :
    Bool :=
  let relative :=
    if pattern.base.isEmpty then some path
    else
      let directory := pattern.base ++ "/"
      if path.startsWith directory then some ((path.drop directory.length).toString) else none
  match relative with
  | none => false
  | some relative =>
    let components := relative.splitOn "/"
    if pattern.directoryOnly then
      -- Directory-only: match the path itself when it *is* a directory, or any ancestor directory.
      (isDirectory && pathMatches pattern.segments components) ||
        prefixMatches pattern.segments components.dropLast
    else
      pathMatches pattern.segments components ||
        prefixMatches pattern.segments components.dropLast

/-- One ignore file's patterns, in file order. Layers are held in **increasing precedence**, so a
later layer overrides an earlier one and, within a layer, a later pattern overrides an earlier one —
git's "nearer file wins, last match in a file wins" (`notes/01-discovery.md` §10.1). -/
private structure IgnoreLayer where
  patterns : Array IgnorePattern
  origin : String

private def readIgnoreFile (path : FilePath) (base : String) : IO IgnoreLayer := do
  let text ← IO.FS.readFile path
  let patterns := (text.splitOn "\n").filterMap (compileIgnoreLine base)
  return { patterns := patterns.toArray, origin := path.toString }

/-- Whether the ignore stack excludes `path`. Later layers and later patterns win. -/
private def ignored (layers : Array IgnoreLayer) (path : String) (isDirectory : Bool) : Bool :=
  layers.foldl (init := false) fun verdict layer =>
    layer.patterns.foldl (init := verdict) fun verdict pattern =>
      if pattern.matches path isDirectory then !pattern.negated else verdict

/-! ## Git configuration, without spawning `git`

Reading `core.excludesFile` by parsing git's own configuration files keeps `git` off the critical
path: lean-fmt does not require it on `PATH` to format a repository, and discovery pays no process
spawn. This is deliberately **partial** — `include`/`includeIf` directives are not followed, so a
global ignore file reachable only through a conditional include is not applied
(`notes/01-discovery.md` §10.2, open question 5). -/

private def expandHome (path : String) : IO String := do
  if path.startsWith "~/" then
    match ← IO.getEnv "HOME" with
    | some home => return home ++ (path.drop 1).toString
    | none => return path
  return path

/-- Extract `core.excludesfile` from a git-style INI file. Section and key names are case-insensitive,
which is why both are lowered before comparison. -/
private def excludesFileIn? (path : FilePath) : IO (Option String) := do
  unless ← path.pathExists do return none
  let text ← IO.FS.readFile path
  let mut currentSection := ""
  for line in text.splitOn "\n" do
    let line := line.trimAscii.toString
    if line.startsWith "[" then
      let name := ((line.drop 1).toString.takeWhile (· != ']')).trimAscii.toString.toLower
      -- `[core]` and `[core "sub"]` both start with `core`; only the bare section carries this key.
      currentSection := (name.takeWhile (· != ' ')).trimAscii.toString
    else
      match line.splitOn "=" with
      | key :: first :: rest =>
        let key := key.trimAscii.toString.toLower
        let value := (String.intercalate "=" (first :: rest)).trimAscii.toString
        if currentSection == "core" && key == "excludesfile" then
          return some (← expandHome value)
      | _ => pure ()
  return none

private def globalIgnoreFile? : IO (Option FilePath) := do
  let mut candidates : Array FilePath := #[]
  if let some path ← IO.getEnv "GIT_CONFIG_GLOBAL" then candidates := candidates.push path
  let configHome ← match ← IO.getEnv "XDG_CONFIG_HOME" with
    | some path => pure (some (FilePath.mk path))
    | none => pure ((← IO.getEnv "HOME").map fun home => FilePath.mk home / ".config")
  if let some home := configHome then candidates := candidates.push (home / "git" / "config")
  if let some home ← IO.getEnv "HOME" then
    candidates := candidates.push (FilePath.mk home / ".gitconfig")
  for candidate in candidates do
    if let some configured ← excludesFileIn? candidate then
      let path := FilePath.mk configured
      if ← path.pathExists then return some path
  -- git's documented default when `core.excludesFile` is unset.
  if let some home := configHome then
    let path := home / "git" / "ignore"
    if ← path.pathExists then return some path
  return none

/-- The repository root governing `root`: the nearest ancestor holding `.git`, ascending to the
filesystem root. This may sit **above** the project root, because a Lean project is commonly a
subdirectory of a larger repository (`notes/01-discovery.md` §10.3). `.git` may be a directory or a
file (a worktree or submodule gitlink), so both forms are accepted. -/
private partial def repositoryRoot? (directory : FilePath) : IO (Option FilePath) := do
  if ← (directory / ".git").pathExists then return some directory
  match directory.parent with
  | some parent => if parent == directory then return none else repositoryRoot? parent
  | none => return none

/-- `.git/info/exclude` for a repository root, following a `.git` **file** (`gitdir: <path>`) to the
real git directory when necessary. -/
private def repositoryExclude? (repository : FilePath) : IO (Option FilePath) := do
  let dotGit := repository / ".git"
  let gitDirectory ←
    if ← dotGit.isDir then pure dotGit
    else do
      let text ← IO.FS.readFile dotGit
      let trimmed := text.trimAscii
      if trimmed.startsWith "gitdir:" then
        let target := ((trimmed.drop "gitdir:".length).toString).trimAscii.toString
        let target := FilePath.mk target
        pure (if target.isAbsolute then target else repository / target)
      else pure dotGit
  let path := gitDirectory / "info" / "exclude"
  return if ← path.pathExists then some path else none

/-! ## The walk -/

/-- The result of one discovery walk: every candidate source that survived the floor and the ignore
sources, and the configuration governing each directory that declared one.

`configs` is keyed by the **root-relative directory** the config governs, so resolving a file is a
prefix search over an array held in memory — never a filesystem ascent per file. -/
structure Discovery where
  private mk ::
  root : FilePath
  /-- Root-relative paths of candidate `.lean` sources, in walk order. -/
  sources : Array String
  /-- `(governed directory, its effective configuration)`, deepest-last. -/
  configs : Array (String × FormatterConfig)
  /-- The configuration for a file no entry in `configs` governs — the root config, or the `--config`
  override, or built-in defaults. -/
  fallback : FormatterConfig
  /-- The ignore sources consulted, in increasing precedence, for `config show`. -/
  ignoreSources : Array String

/-- The configuration governing one root-relative path: the **closest** config at or above its
directory. Hierarchy does not merge — the nearest config applies whole, and inheritance is explicit
through `extend` (`notes/01-discovery.md` §5). -/
def Discovery.governing (discovery : Discovery) (path : String) :
    String × FormatterConfig := Id.run do
  let mut best := ("", discovery.fallback)
  let mut bestDepth := 0
  for (directory, config) in discovery.configs do
    let governs := directory.isEmpty || path.startsWith (directory ++ "/")
    if governs && (directory.length ≥ bestDepth) then
      best := (directory, config)
      bestDepth := directory.length
  return best

def Discovery.configFor (discovery : Discovery) (path : String) : FormatterConfig :=
  (discovery.governing path).2

/-- The directory whose configuration governs `path`. Two paths sharing a key share a configuration,
so a caller can resolve one `RulePlan` per distinct configuration rather than one per file. -/
def Discovery.configKeyFor (discovery : Discovery) (path : String) : String :=
  (discovery.governing path).1

private def isLeanSource (path : FilePath) : Bool := path.extension == some "lean"

/-- Walk the project once, collecting sources, configurations, and ignore state together.

The single walk is the shape `RCD-IMPL`'s stop rule demands: a per-file filesystem ascent is what this
structure exists to avoid. Pruning is sound precisely because git's directory-exclusion rule holds — a
directory that is ignored can contain no re-included file, so not descending into it cannot lose one
(`notes/01-discovery.md` §4.2, §10.1). -/
private partial def walkDirectory (root : FilePath) (explicit? : Option FormatterConfig)
    (directory : FilePath) (relative : String) (current : FormatterConfig)
    (layers : Array IgnoreLayer) (accumulated : Discovery) : IO Discovery := do
  let mut current := current
  let mut layers := layers
  let mut accumulated := accumulated
  -- A config in this directory governs this subtree, unless `--config` overrode discovery entirely.
  if explicit?.isNone then
    if let some configPath ← recognizedConfigIn? directory then
      current ← FormatterConfig.loadFrom root configPath relative
      accumulated := { accumulated with configs := accumulated.configs.push (relative, current) }
  if current.respectGitignore then
      for name in [".gitignore", ".ignore"] do
      let path := directory / name
      if ← path.pathExists then
        let layer ← readIgnoreFile path relative
        layers := layers.push layer
        accumulated := { accumulated with
          ignoreSources := accumulated.ignoreSources.push layer.origin }
  let entries ← directory.readDir
  let entries := entries.qsort fun left right => left.fileName < right.fileName
  let mut subdirectories : Array (FilePath × String) := #[]
  for entry in entries do
    let childRelative := if relative.isEmpty then entry.fileName else relative ++ "/" ++ entry.fileName
    if ← entry.path.isDir then
      -- Gate 1 floor: `.lake` is never descended into and never selected, by any path form.
      if entry.fileName == ".lake" || entry.fileName == ".git" then continue
      if current.respectGitignore && ignored layers childRelative true then continue
      if current.excludePatterns.any (·.matches childRelative) then continue
      subdirectories := subdirectories.push (entry.path, childRelative)
    else if isLeanSource entry.path then
      if current.respectGitignore && ignored layers childRelative false then continue
      accumulated := { accumulated with sources := accumulated.sources.push childRelative }
  for (path, childRelative) in subdirectories do
    accumulated ← walkDirectory root explicit? path childRelative current layers accumulated
  return accumulated

/-- Run discovery for one project root.

`explicit?` is a `--config` override: it applies to every file, no directory is searched for a nested
config, and a nested config that exists is inert (`notes/01-discovery.md` §5.1). -/
def run (root : FilePath) (explicit? : Option FilePath) : IO Discovery := do
  let root ← IO.FS.realPath root
  let fallback ← match explicit? with
    | some path =>
      unless ← path.pathExists do
        throw <| IO.userError s!"formatter configuration does not exist: {path}"
      FormatterConfig.loadFrom root path ""
    | none =>
      match ← recognizedConfigIn? root with
      | none => pure (← FormatterConfig.load root none)
      | some path => FormatterConfig.loadFrom root path ""
  let mut layers : Array IgnoreLayer := #[]
  let mut ignoreSources : Array String := #[]
  if fallback.respectGitignore then
    -- Lowest precedence first: global ignore, then the repository's own excludes.
    if let some path ← globalIgnoreFile? then
      let layer ← readIgnoreFile path ""
      layers := layers.push layer
      ignoreSources := ignoreSources.push layer.origin
    if let some repository ← repositoryRoot? root then
      if let some path ← repositoryExclude? repository then
        let layer ← readIgnoreFile path ""
        layers := layers.push layer
        ignoreSources := ignoreSources.push layer.origin
  let seed : Discovery := {
    root
    sources := #[]
    configs := #[]
    fallback
    ignoreSources
  }
  -- The root's own config is the fallback and is already loaded; record it so `config show` can name
  -- it, without letting the walk load it a second time.
  let seed := if explicit?.isNone then seed else seed
  walkDirectory root (explicit?.map fun _ => fallback) root "" fallback layers seed

/-- Why a path was or was not selected, as the gate number of `notes/01-discovery.md` §11. `selected`
is gate 0. Reported by `config show` so "would this file be formatted, and why not" has an answer. -/
inductive Gate where
  /-- Selected. -/
  | selected
  /-- Gate 1: outside the root, not a `.lean` source, or inside `.lake`. -/
  | floor
  /-- Gate 2: excluded by a git ignore source. -/
  | ignoreSource
  /-- Gate 3: excluded by the configuration's `exclude`. -/
  | configExclude
  /-- Gate 4: not matched by a non-empty `include`. -/
  | configInclude
  deriving BEq, Repr

def Gate.number : Gate → Nat
  | .selected => 0
  | .floor => 1
  | .ignoreSource => 2
  | .configExclude => 3
  | .configInclude => 4

def Gate.describe : Gate → String
  | .selected => "selected"
  | .floor => "gate 1: outside the project, not a Lean source, or inside .lake"
  | .ignoreSource => "gate 2: excluded by a git ignore source"
  | .configExclude => "gate 3: excluded by the configuration's exclude"
  | .configInclude => "gate 4: not matched by the configuration's include"

/-- Decide selection for a **discovered** path. Gates 2 and 3 already ran during the walk (they prune),
so what remains is gate 3 for files (directories were pruned) and gate 4.

Explicit paths take the other route: they skip gates 2–4 unless `force-exclude` is on, and never
consult gate 4 at all (`notes/01-discovery.md` §11). -/
def Discovery.gateFor (discovery : Discovery) (path : String) : Gate :=
  let config := discovery.configFor path
  if config.excludePatterns.any (·.matches path) then .configExclude
  else if !config.includePatterns.isEmpty && !config.includePatterns.any (·.matches path) then
    .configInclude
  else .selected

/-- Selection for an **arbitrary** path, discovered or not — the question `config show` asks
(`notes/01-discovery.md` §12).

`gateFor` above is only defined on paths the walk produced, so it may assume gates 2 and 3 already
pruned. This one cannot: it is handed a path from the command line, which may sit under a directory the
walk never descended into. So it re-asks gate 3 against every ancestor directory as well as the file
itself, because an `exclude = ["vendor"]` pattern names the directory and never the files beneath it —
the walk expresses that by pruning, and pruning leaves no per-file record to read back.

Order matters: gate 3 is asked *before* absence-from-`sources`, since a config-excluded directory is
also absent, and reporting "excluded by a git ignore source" for a path the user's own `exclude` key
removed would send them to the wrong file to fix it. -/
def Discovery.explain (discovery : Discovery) (path : String) : Gate :=
  let config := discovery.configFor path
  let segments := path.splitOn "/"
  let ancestors := (List.range segments.length).map fun count =>
    String.intercalate "/" (segments.take (count + 1))
  if config.excludePatterns.any (fun pattern => ancestors.any pattern.matches) then .configExclude
  else if !discovery.sources.contains path then .ignoreSource
  else discovery.gateFor path

/-- The discovered sources that survive configured selection, root-relative and in walk order. -/
def Discovery.selectedSources (discovery : Discovery) : Array String :=
  discovery.sources.filter fun path => discovery.gateFor path == .selected

end LeanFmt.Internal.Discovery
