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
import all Test.Unit.Fixtures

import Lean.Data.Lsp

open LeanFmt LeanFmt.Internal
open LeanFmt.Test.Unit.Fixtures

namespace LeanFmt.Test.Unit.Config

/-! ## Config

Parsing, inheritance, and selection: what a `lean-fmt.toml` means, what a nested one inherits, and
what rule plan a config plus a command line produce. Discovery is here too, because which files a run
selects is decided by the same config it reads. -/

private def testConfig : IO Unit := do
  let directory ← IO.FS.createTempDir
  let configPath := directory / "lean-fmt.toml"
  -- Category/selector machinery is exercised on the source-tier `security` category (FMT001 control
  -- byte, FMT002 bidi mark), the sole source-tier vehicle after the `text` category (FMT001/FMT002)
  -- was retired into the formatter. `redundancy` (FMT008/11/13, syntax) is the
  -- disjoint category that must select none of these findings.
  let ctl (n : Nat) : String := String.ofList [Char.ofNat n]
  let secBytes := "def s := \"a" ++ ctl 0x00 ++ "b\"\n-- x" ++ ctl 0x202e ++ "y\n"
  try
    IO.FS.writeFile configPath
        "\
include = [\"LeanFmt/**/*.lean\", \"Main.lean\"]\n\
exclude = [\"LeanFmt/Generated/**\"]\n\
select = [\"security\"]\n\
ignore = [\"FMT002\"]\n\
[per-file-ignores]\n\
\"LeanFmt/Legacy/*.lean\" = [\"FMT001\"]\n"
    let config ← FormatterConfig.load directory
    ensure (config.includesPath "LeanFmt/Internal/File.lean")
        "recursive include pattern did not match"
    ensure (config.includesPath "Main.lean") "root-file include pattern did not match"
    ensure (!(config.includesPath "LeanFmt/Generated/File.lean")) "exclude pattern did not win"
    ensure (!(config.includesPath "Other.lean")) "unmatched path was included"
    let .ok plan :=
      config.rulePlan {} | throw <| IO.userError "valid configured selectors were rejected"
    -- Specificity precedence: config `ignore = [FMT002]` (exact) outranks `select = [security]`
    -- (category), so only FMT001 survives.
    ensure (plan.activeCount == 1) "configured ignore did not win"
    let findings := runSourceRules secBytes defaultLineWidth
    ensure ((plan.findings "LeanFmt/File.lean" findings).map (·.code) == #["FMT001"])
        "configured selector projection was wrong"
    ensure ((plan.findings "LeanFmt/Legacy/File.lean" findings).isEmpty)
        "per-file ignore did not win"
    let .ok cliPlan :=
      config.rulePlan
        { select := #["FMT002"],
          ignore := #["FMT001"] } | throw <| IO.userError "valid CLI selectors were rejected"
    ensure
        (cliPlan.activeCount == 1 &&
          (cliPlan.findings "Main.lean" findings).map (·.code) == #["FMT002"])
        "CLI selection did not replace config selection or ignore precedence changed"
    ensure
        (match config.rulePlan { select := #["UNKNOWN"] } with
        | .error _ => true
        | .ok _ => false)
        "unknown CLI selector was accepted"
    -- The whole `security` category resolves through registry-derived category machinery — no hardcoded
    -- list. All security rules are stable, so no preview gate is needed to select them.
    let .ok secPlan :=
      config.rulePlan
        {
          select :=
            #["security"] } | throw <| IO.userError "the 'security' category selector was rejected"
    ensure ((secPlan.findings "A.lean" findings).map (·.code) == #["FMT001", "FMT002"])
        "the security category did not select both control-byte rules"
    -- Preview gate on a category selector, now over a MIXED category: `redundancy` holds
    -- FMT008 and FMT009 (preview) and FMT011 (stable, default-off — the "stable-optional"
    -- outcome). So the category resolves to exactly the stable member without preview mode, and to all
    -- three with it. The mixed case is the interesting one.
    let .ok gated :=
      config.rulePlan
        {
          select :=
            #["redundancy"] } | throw <| IO.userError "a partly-preview category was rejected"
    ensure (gated.selected == #["FMT011"])
        "the redundancy category did not resolve to exactly its stable member without preview mode"
    let .ok previewed :=
      config.rulePlan
        { select := #["redundancy"],
          preview :=
            true } | throw <| IO.userError "the preview category was rejected under preview mode"
    ensure (previewed.activeCount == 3) "preview mode did not unlock the redundancy category"
    -- `stable-optional`, stated directly. FMT011 is reachable by `all`, by
    -- its category, and by its exact code with NO preview gate, and is absent from `default`. That
    -- combination is the whole outcome: promoted out of preview on correctness, kept off the default
    -- path on cost.
    ensure
        (match config.rulePlan { select := #["FMT011"] } with
        | .ok p => p.selected == #["FMT011"]
        | .error _ => false)
        "a stable default-off rule was not selectable by its exact code without preview mode"
    let .ok allSel :=
      config.rulePlan
        { select := #["all"] } | throw <| IO.userError "the 'all' selector was rejected"
    ensure (allSel.selected.contains "FMT011")
        "'all' did not reach a stable default-off rule without preview mode"
    let .ok defSel :=
      config.rulePlan
        { select := #["default"] } | throw <| IO.userError "the 'default' selector was rejected"
    ensure (!defSel.selected.contains "FMT011")
        "a stable default-off rule leaked into the default set"
    -- Explicit preview-code selection is still an error without preview mode, and succeeds with it.
    -- FMT008 carries this now that FMT011 is stable.
    ensure
        (match config.rulePlan { select := #["FMT008"] } with
        | .error _ => true
        | .ok _ => false)
        "an explicit preview-code selection was accepted without preview mode"
    ensure
        (match config.rulePlan { select := #["FMT008"], preview := true } with
        | .ok p => p.selected == #["FMT008"]
        | .error _ => false)
        "preview mode did not admit an explicit preview-code selection"
    -- Specificity keeps an exact select over a category ignore (the case flat subtraction dropped).
    let .ok keep :=
      config.rulePlan
        { select := #["FMT011"],
          ignore :=
            #["redundancy"] } | throw <| IO.userError "exact-vs-category precedence rejected a valid plan"
    ensure (keep.selected == #["FMT011"]) "an exact select did not outrank a category ignore"
    -- A retired code is accepted (non-breaking), selects no rule, and raises a notice -- REMOVED with
    -- the rest of the retired-code coverage (docs/adding-a-rule.md §"Retiring a rule"). It selected
    -- FMT001, which the renumbering turned into a live default security rule, so the case would now
    -- assert that
    -- selecting a live rule yields an empty plan. There is no code left that can exercise this path:
    -- with `reservedCodes` empty, `selectorsValid` rejects anything that is not live, so "accepted
    -- with a notice" has no possible input until a rule retires.
    -- Fixability axis: a selected rule made unfixable is still selected, but out of `fixableSelected`.
    let .ok unfix :=
      config.rulePlan
        { select := #["FMT011"],
          unfixable :=
            #["FMT011"] } | throw <| IO.userError "the unfixable axis rejected a valid plan"
    ensure (unfix.selected == #["FMT011"] && unfix.fixableSelected.isEmpty)
        "unfixable did not withhold FMT011's fix while keeping it selected"
    -- The remaining precedence-matrix edges beyond the cases above.
    -- (a) Tie → ignore: an exact select and an exact ignore of the same code are equal specificity, so
    -- ignore wins and the rule is dropped.
    let .ok tie :=
      config.rulePlan
        { select := #["FMT002"],
          ignore := #["FMT002"] } | throw <| IO.userError "an exact select/ignore tie was rejected"
    ensure (tie.activeCount == 0) "an exact select/ignore tie did not resolve to ignore"
    -- (b) `all` expands to the stable set; `default` expands to the default-ON set. These now
    -- DIFFER — FMT011 is stable and default-off — and that divergence is the point of the
    -- `stable-optional` outcome, so it is asserted rather than assumed away. Neither admits a preview
    -- rule without the gate; `all` + preview unlocks the whole registry.
    let stableCount := (allRuleInfos.filter (·.lifecycle == .stable)).size
    let defaultCount := (allRuleInfos.filter (·.defaultEnabled)).size
    ensure (defaultCount < stableCount)
        "no stable rule is default-off, so the stable-optional outcome has no live instance"
    let .ok allPlan :=
      config.rulePlan
        { select := #["all"] } | throw <| IO.userError "the 'all' selector was rejected"
    let .ok defPlan :=
      config.rulePlan
        { select := #["default"] } | throw <| IO.userError "the 'default' selector was rejected"
    ensure (allPlan.activeCount == stableCount)
        "'all' did not expand to exactly the stable set without preview"
    ensure (defPlan.activeCount == defaultCount)
        "'default' did not expand to exactly the default-enabled set"
    let .ok allPreview :=
      config.rulePlan
        { select := #["all"],
          preview := true } | throw <| IO.userError "'all' under preview was rejected"
    ensure (allPreview.activeCount == allRuleInfos.size)
        "'all' under preview did not unlock the whole registry"
    -- (c) `extend-select` always adds, across the CLI-owns-selection boundary: with no CLI `select`, the
    -- config selection (security minus the config's exact `ignore = [FMT002]`) still applies, and a CLI
    -- extend-select adds FMT011 on top (no preview gate needed). Result: FMT001 + FMT011.
    let .ok extended :=
      config.rulePlan
        {
          extendSelect :=
            #["FMT011"] } | throw <| IO.userError "extend-select over the config selection was rejected"
    ensure (extended.selected == #["FMT001", "FMT011"])
        "extend-select did not add to the config selection while keeping the config ignore"
    IO.FS.writeFile configPath "unknown = true\n"
    let rejected ←
      try
        discard <| FormatterConfig.load directory
        pure false
      catch _ =>
        pure true
    ensure rejected "unknown configuration key was accepted"
    -- `[cache] closure`: the closure-currency mode. Default is `artifacts`; `interface` is
    -- accepted and lands on the resolved configuration; a bad value, a flat spelling, and an
    -- unknown section key are all rejected rather than silently defaulted.
    IO.FS.writeFile configPath ""
    ensure ((← FormatterConfig.load directory).closureMode == .artifacts)
        "the default closure mode is not artifacts"
    IO.FS.writeFile configPath "[cache]\nclosure = \"interface\"\n"
    ensure ((← FormatterConfig.load directory).closureMode == .interface)
        "closure = interface did not resolve to the interface mode"
    for document in
      ["[cache]\nclosure = \"everything\"\n", "closure = \"interface\"\n",
        "[cache]\nunknown = true\n"] do
      IO.FS.writeFile configPath document
      let rejected ←
        try
          discard <| FormatterConfig.load directory
          pure false
        catch _ =>
          pure true
      ensure rejected s!"an invalid [cache] closure configuration was accepted: {document}"
  finally
    IO.FS.removeDirAll directory

/-- Hierarchical configuration discovery.

Everything here is filesystem-real: a temporary tree with actual config files, actual `.gitignore`
files, and actual sources, walked by the same `Discovery.run` a real run uses. A unit test that hands a
hand-built `FormatterConfig` to the matcher would pass while discovery picked the wrong file, which is
the failure this test exists to prevent.

`.gitignore` handling is asserted through `Discovery.run` rather than against the pattern compiler
directly, for the same reason: the compiler being right about `build/` is worth nothing if the walk
does not prune `build/` — and pruning, not per-file matching, is what git's directory-exclusion rule
licenses. -/
private def testDiscovery : IO Unit := do
  let directory ← IO.FS.createTempDir
  let root ← IO.FS.realPath directory
  let write (relative content : String) : IO Unit := do
    let path := root / System.FilePath.mk relative
    if let some parent := path.parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile path content
  try
    -- Both recognized names present is a hard error, never a silent precedence win.
    write ".lean-fmt.toml" "[lint]\nselect = [\"security\"]\n"
    write "lean-fmt.toml" "[lint]\nselect = [\"all\"]\n"
    let ambiguous ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure ambiguous "two recognized configuration names in one directory were accepted"
    IO.FS.removeFile (root / "lean-fmt.toml")
    -- The closest config wins outright: `sub` does not inherit the root's `exclude`, and the root
    -- does not acquire `sub`'s width. No implicit merging.
    write ".lean-fmt.toml"
        "\
exclude = [\"skipped\"]\n\
[format]\n\
line-width = 60\n"
    write "sub/.lean-fmt.toml" "[format]\nline-width = 42\n"
    write "A.lean" "module\n"
    write "sub/B.lean" "module\n"
    write "skipped/C.lean" "module\n"
    write "sub/skipped/D.lean" "module\n"
    let discovery ← Discovery.run root none
    ensure ((discovery.configFor "A.lean").format.lineWidth == 60)
        "the root configuration did not govern a root file"
    ensure ((discovery.configFor "sub/B.lean").format.lineWidth == 42)
        "the closest configuration did not govern a nested file"
    ensure ((discovery.configFor "sub/B.lean").excludePatterns.isEmpty)
        "the nested configuration inherited the root's exclude — the hierarchy must not merge"
    ensure (discovery.explain "skipped/C.lean" == .configExclude)
        "an excluded directory's contents were not reported as configuration-excluded"
    ensure (discovery.explain "sub/skipped/D.lean" == .selected)
        "the root's exclude reached a subtree its own configuration governs"
    ensure (discovery.configKeyFor "A.lean" != discovery.configKeyFor "sub/B.lean")
        "two distinct effective configurations shared one plan key"
    -- `extend` composes: scalars and base arrays replace, `extend-*` concatenates, and `extend`
    -- itself is not inherited. Patterns anchor at the *declaring* file's directory.
    write "base.toml"
        "\
[format]\n\
line-width = 90\n\
[lint]\n\
select = [\"security\"]\n\
extend-select = [\"FMT008\"]\n"
    write "sub/.lean-fmt.toml"
        "\
extend = \"../base.toml\"\n\
[format]\n\
line-width = 42\n\
[lint]\n\
extend-select = [\"FMT009\"]\n"
    let extended ← Discovery.run root none
    let child := extended.configFor "sub/B.lean"
    ensure (child.format.lineWidth == 42) "the extending file did not win a scalar"
    ensure (child.selectedSelectors == #["security"]) "the parent's base array was not inherited"
    ensure (child.extendSelectSelectors == #["FMT008", "FMT009"])
        "extend-select did not concatenate parent-then-child"
    ensure (child.contributingFiles.size == 2)
        "the extend chain did not record both contributing files"
    -- A cycle terminates as an error rather than a hang or a depth-limit surprise.
    write "cycle-a.toml" "extend = \"cycle-b.toml\"\n"
    write "cycle-b.toml" "extend = \"cycle-a.toml\"\n"
    write "sub/.lean-fmt.toml" "extend = \"../cycle-a.toml\"\n"
    let cyclic ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure cyclic "an extend cycle was accepted"
    IO.FS.removeFile (root / "sub" / ".lean-fmt.toml")
    -- Migration: a flat linter key still works and says so; setting it in both places is an
    -- error; `line-width` at the top level is an error rather than a silent no-op.
    write ".lean-fmt.toml" "select = [\"security\"]\n"
    let migrated ← Discovery.run root none
    ensure (migrated.fallback.selectedSelectors == #["security"])
        "a flat linter key stopped working"
    ensure (migrated.fallback.notices.any fun notice => (notice.splitOn "select").length > 1)
        "a flat linter key produced no deprecation notice"
    write ".lean-fmt.toml" "select = [\"security\"]\n[lint]\nselect = [\"all\"]\n"
    let both ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure both "the same linter key set flat and under [lint] was accepted"
    write ".lean-fmt.toml" "line-width = 80\n"
    let misplaced ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure misplaced "line-width at the top level was accepted"
    -- The width bound is enforced at load, not at render.
    for width in ["0", "1001"] do
      write ".lean-fmt.toml" s!"[format]\nline-width = {width}\n"
      let bounded ←
        try
          discard <| Discovery.run root none;
          pure false
        catch _ =>
          pure true
      ensure bounded s!"line-width = {width} was accepted outside 1..1000"
    -- `pinned-comments` and `declaration-body`: defaults hold without a config; setting them
    -- parses; `[]` is a real value (it disables pinning, where absence would keep the default);
    -- a child inherits an unset key and replaces a set one; both misplaced at the top level and
    -- both malformed are errors.
    write ".lean-fmt.toml" "[format]\nline-width = 100\n"
    let defaults ← Discovery.run root none
    ensure (defaults.fallback.format.pinnedComments == #["shake: keep"])
        "pinned-comments lost its default"
    ensure (defaults.fallback.format.declarationBody == .nextLine)
        "declaration-body lost its default"
    ensure (defaults.fallback.format.declarationWhere == .sameLine)
        "declaration-where lost its default"
    ensure (defaults.fallback.format.emptyStructureInstance == .compact)
        "empty-structure-instance lost its default"
    write ".lean-fmt.toml"
        "[format]\npinned-comments = [\"fmt: off\", \"shake: keep\"]\ndeclaration-body = \"same-line\"\n"
    let configured ← Discovery.run root none
    ensure (configured.fallback.format.pinnedComments == #["fmt: off", "shake: keep"])
        "pinned-comments did not parse"
    ensure (configured.fallback.format.declarationBody == .sameLine)
        "declaration-body did not parse"
    write ".lean-fmt.toml" "[format]\ndeclaration-where = \"next-line\"\n"
    let configuredWhere ← Discovery.run root none
    ensure (configuredWhere.fallback.format.declarationWhere == .nextLine)
        "declaration-where did not parse"
    write ".lean-fmt.toml" "[format]\nempty-structure-instance = \"spaced\"\n"
    let configuredEmpty ← Discovery.run root none
    ensure (configuredEmpty.fallback.format.emptyStructureInstance == .spaced)
        "empty-structure-instance did not parse"
    write ".lean-fmt.toml" "[format]\npinned-comments = []\n"
    let disabled ← Discovery.run root none
    ensure (disabled.fallback.format.pinnedComments.isEmpty)
        "pinned-comments = [] kept the default instead of disabling"
    write "pins.toml"
        "[format]\npinned-comments = [\"shake: keep\"]\ndeclaration-body = \"same-line\"\n"
    write "sub/.lean-fmt.toml"
        "extend = \"../pins.toml\"\n[format]\npinned-comments = [\"fmt: off\"]\n"
    write "sub/deeper/.lean-fmt.toml" "extend = \"../.lean-fmt.toml\"\n"
    write "sub/deeper/C.lean" "module\n"
    let pinnedChain ← Discovery.run root none
    ensure ((pinnedChain.configFor "sub/B.lean").format.pinnedComments == #["fmt: off"])
        "a child's pinned-comments did not replace the parent's"
    ensure ((pinnedChain.configFor "sub/deeper/C.lean").format.pinnedComments == #["fmt: off"])
        "an unset child's pinned-comments did not inherit"
    ensure ((pinnedChain.configFor "sub/deeper/C.lean").format.declarationBody == .sameLine)
        "an unset child's declaration-body did not inherit"
    IO.FS.removeFile (root / "sub" / "deeper" / ".lean-fmt.toml")
    write "sub/.lean-fmt.toml" "[format]\nline-width = 42\n"
    write ".lean-fmt.toml" "pinned-comments = [\"shake: keep\"]\n"
    let misplacedPins ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure misplacedPins "pinned-comments at the top level was accepted"
    write ".lean-fmt.toml" "declaration-body = \"same-line\"\n"
    let misplacedBody ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure misplacedBody "declaration-body at the top level was accepted"
    write ".lean-fmt.toml" "[format]\npinned-comments = [\"\"]\n"
    let emptyPhrase ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure emptyPhrase "an empty pinned-comments phrase was accepted"
    write ".lean-fmt.toml" "[format]\ndeclaration-body = \"flat\"\n"
    let badBody ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure badBody "an unknown declaration-body value was accepted"
    write ".lean-fmt.toml" "[format]\nempty-structure-instance = \"loose\"\n"
    let badEmpty ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure badEmpty "an unknown empty-structure-instance value was accepted"
    write ".lean-fmt.toml" "empty-structure-instance = \"compact\"\n"
    let misplacedEmpty ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure misplacedEmpty "empty-structure-instance at the top level was accepted"
    write ".lean-fmt.toml" "declaration-where = \"next-line\"\n"
    let misplacedWhere ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure misplacedWhere "declaration-where at the top level was accepted"
    write ".lean-fmt.toml" "[format]\ndeclaration-where = \"hanging\"\n"
    let badWhere ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure badWhere "an unknown declaration-where value was accepted"
    -- `magic-trailing-comma`: default `respect` holds without a config; `ignore` parses; a child
    -- inherits an unset key; misplaced at the top level and malformed are errors; and it moves
    -- the configuration identity like every `[format]` key.
    write ".lean-fmt.toml" "[format]\nline-width = 100\n"
    let commaDefaults ← Discovery.run root none
    ensure (commaDefaults.fallback.format.magicTrailingComma == .respect)
        "magic-trailing-comma lost its default"
    write ".lean-fmt.toml" "[format]\nmagic-trailing-comma = \"ignore\"\n"
    let commaConfigured ← Discovery.run root none
    ensure (commaConfigured.fallback.format.magicTrailingComma == .ignore)
        "magic-trailing-comma did not parse"
    ensure
        (commaDefaults.fallback.format.identityString !=
          commaConfigured.fallback.format.identityString)
        "magic-trailing-comma did not change the configuration identity"
    write "sub/.lean-fmt.toml" "extend = \"../.lean-fmt.toml\"\n[format]\nline-width = 42\n"
    write "sub/B.lean" "module\n"
    let commaChain ← Discovery.run root none
    ensure ((commaChain.configFor "sub/B.lean").format.magicTrailingComma == .ignore)
        "an unset child's magic-trailing-comma did not inherit"
    write "sub/.lean-fmt.toml" "[format]\nline-width = 42\n"
    write ".lean-fmt.toml" "magic-trailing-comma = \"ignore\"\n"
    let misplacedComma ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure misplacedComma "magic-trailing-comma at the top level was accepted"
    write ".lean-fmt.toml" "[format]\nmagic-trailing-comma = \"explode\"\n"
    let badComma ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure badComma "an unknown magic-trailing-comma value was accepted"
    -- `import-layout` and `import-groups`: defaults, parsing, identity movement (both are
    -- [format] keys), and misplaced/malformed errors.
    write ".lean-fmt.toml" "[format]\nline-width = 100\n"
    let layoutDefaults ← Discovery.run root none
    ensure (layoutDefaults.fallback.format.importLayout == .grouped)
        "import-layout lost its default"
    ensure (layoutDefaults.fallback.format.importGroups == Imports.defaultImportGroups)
        "import-groups lost its default"
    write ".lean-fmt.toml"
        "[format]\nimport-layout = \"canonical\"\nimport-groups = [\"Std\", \"Lean\"]\n"
    let layoutConfigured ← Discovery.run root none
    ensure (layoutConfigured.fallback.format.importLayout == .canonical)
        "import-layout did not parse"
    ensure (layoutConfigured.fallback.format.importGroups == #["Std", "Lean"])
        "import-groups did not parse"
    ensure
        (layoutDefaults.fallback.format.identityString !=
          layoutConfigured.fallback.format.identityString)
        "import-layout/import-groups did not change the configuration identity"
    write ".lean-fmt.toml" "import-layout = \"canonical\"\n"
    let misplacedLayout ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure misplacedLayout "import-layout at the top level was accepted"
    write ".lean-fmt.toml" "[format]\nimport-layout = \"fancy\"\n"
    let badLayout ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure badLayout "an unknown import-layout value was accepted"
    write ".lean-fmt.toml" "[format]\nimport-groups = [\"\"]\n"
    let emptyGroup ←
      try
        discard <| Discovery.run root none;
        pure false
      catch _ =>
        pure true
    ensure emptyGroup "an empty import-groups prefix was accepted"
    IO.FS.removeFile (root / "sub" / ".lean-fmt.toml")
    -- Both new keys are [format] keys: each moves the configuration identity.
    write ".lean-fmt.toml" "[format]\nline-width = 100\n"
    let identityBase ← Discovery.run root none
    write ".lean-fmt.toml" "[format]\nline-width = 100\npinned-comments = []\n"
    let identityPins ← Discovery.run root none
    ensure
        (identityBase.fallback.format.identityString != identityPins.fallback.format.identityString)
        "pinned-comments did not change the configuration identity"
    write ".lean-fmt.toml" "[format]\nline-width = 100\ndeclaration-body = \"same-line\"\n"
    let identityBody ← Discovery.run root none
    ensure
        (identityBase.fallback.format.identityString != identityBody.fallback.format.identityString)
        "declaration-body did not change the configuration identity"
    write ".lean-fmt.toml" "[format]\nline-width = 100\nempty-structure-instance = \"spaced\"\n"
    let identityEmpty ← Discovery.run root none
    ensure
        (identityBase.fallback.format.identityString !=
          identityEmpty.fallback.format.identityString)
        "empty-structure-instance did not change the configuration identity"
    write ".lean-fmt.toml" "[format]\nline-width = 100\ndeclaration-where = \"next-line\"\n"
    let identityWhere ← Discovery.run root none
    ensure
        (identityBase.fallback.format.identityString !=
          identityWhere.fallback.format.identityString)
        "declaration-where did not change the configuration identity"
    -- A `.gitignore` prunes, and a nearer file's negation wins over a farther file's exclusion.
    write ".lean-fmt.toml" "[format]\nline-width = 100\n"
    write ".gitignore" "build/\n*.tmp.lean\n"
    write ".git/HEAD" "ref: refs/heads/main\n"
    write "build/Generated.lean" "module\n"
    write "A.tmp.lean" "module\n"
    write "sub/.gitignore" "!*.tmp.lean\n"
    write "sub/A.tmp.lean" "module\n"
    let ignoring ← Discovery.run root none
    ensure (!ignoring.sources.contains "build/Generated.lean") "an ignored directory was walked"
    ensure (!ignoring.sources.contains "A.tmp.lean") "an ignored file was discovered"
    ensure (ignoring.sources.contains "sub/A.tmp.lean")
        "a nearer .gitignore negation did not re-include a file"
    ensure (ignoring.ignoreSources.any (·.endsWith ".gitignore"))
        "the ignore sources were not reported"
    -- The sharp rule, asserted on the identity string itself: a `[format]` key moves it, a
    -- `[lint]` key never does. This is the whole reason the sections are separate keys and not one
    -- flat namespace.
    write ".lean-fmt.toml" "[format]\nline-width = 100\n[lint]\nselect = [\"security\"]\n"
    let lintOnly ← Discovery.run root none
    write ".lean-fmt.toml" "[format]\nline-width = 100\n[lint]\nselect = [\"all\"]\n"
    let lintOther ← Discovery.run root none
    ensure (lintOnly.fallback.format.identityString == lintOther.fallback.format.identityString)
        "a [lint] key changed the configuration identity"
    write ".lean-fmt.toml" "[format]\nline-width = 99\n[lint]\nselect = [\"all\"]\n"
    let formatOther ← Discovery.run root none
    ensure (lintOther.fallback.format.identityString != formatOther.fallback.format.identityString)
        "a [format] key did not change the configuration identity"
    -- Introspection is deterministic and records provenance, not just values.
    let described := formatOther.fallback.describe
    ensure (described == formatOther.fallback.describe) "config introspection was not deterministic"
    ensure
        (described.any fun (key, value, origin) =>
          key == "format.line-width" && value == "99" && origin.endsWith ".lean-fmt.toml:2")
        "config introspection lost a setting's file and line"
    ensure (described.any fun (key, _, origin) => key == "include" && origin == "default")
        "an unset setting was not reported as a default"
    ensure
        (described.any fun (key, value, origin) =>
          key == "format.pinned-comments" && value == "[\"shake: keep\"]" && origin == "default")
        "config introspection lost the pinned-comments default"
    ensure
        (described.any fun (key, value, origin) =>
          key == "format.declaration-body" && value == "next-line" && origin == "default")
        "config introspection lost the declaration-body default"
    ensure
        (described.any fun (key, value, origin) =>
          key == "format.declaration-where" && value == "same-line" && origin == "default")
        "config introspection lost the declaration-where default"
    ensure
        (described.any fun (key, value, origin) =>
          key == "format.empty-structure-instance" && value == "compact" && origin == "default")
        "config introspection lost the empty-structure-instance default"
  finally
    IO.FS.removeDirAll directory

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case :=
  #[{ name := "testConfig", run := testConfig }, { name := "testDiscovery", run := testDiscovery }]

end LeanFmt.Test.Unit.Config
