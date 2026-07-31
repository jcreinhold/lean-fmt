module

public import Test

/-!
# The semantic suite

Port of `tests/fixtures/semantic/run.sh`: acceptance for semantic rule facts. Formatting is deliberately
absent from this capability: the exact formatter uses live syntax and registry state, while this
suite gates compiler diagnostics and owned deprecation occurrences.

The differentials never touch the capture code: Lean's own `--json` frontend is the independent
oracle for both the surfaced-diagnostics fact and the owned-occurrence fact.

Lane: parallel — the acceptance project is a throwaway under a temp dir, repo-root invocations are
all `--no-cache`, and the preamble's facet build is Lake-cached.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace Semantic

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath

/-- `__analyze-exact` at the given capture token, via `lake env` as the old script ran it. -/
private def capture (ctx : Ctx) (setup : System.FilePath) (fixture : String) (token : String)
    (label : String) : IO Lean.Json := do
  let result ←
    expectExit 0 label "lake"
        #["env", ctx.application, "__analyze-exact", setup.toString, fixture, fixture, token]
        (cwd? := some ctx.root)
  parseJson result.stdout label

/-- The artifact of a capture envelope. -/
private def artifactOf (envelope : Lean.Json) (label : String) : IO Lean.Json := do
  let some artifact :=
    jsonAt? envelope
      [.field "artifact"] | throw <| IO.userError s!"{label}: envelope has no artifact"
  return artifact

/-- Byte offset of a 1-based line and 0-based *codepoint* column — the `lean --json` coordinate
system — in the given source. -/
private def byteOffset (source : String) (line col : Nat) : Nat :=
  let lines := source.splitOn "\n"
  let before := (lines.take (line - 1)).foldl (fun acc l => acc + l.utf8ByteSize + 1) 0
  let current := lines[line - 1]?.getD ""
  -- `col` counts codepoints; take that many characters and measure the bytes.
  before + ((current.toList.take col).asString).utf8ByteSize

/-- The `lean --json` oracle: one JSON object per line, for lines that are objects. -/
private def leanOracle (ctx : Ctx) (fixture : String) : IO (Array Lean.Json) := do
  let result ← runProc "lake" #["env", "lean", "--json", fixture] (cwd? := some ctx.root)
  let mut objects := #[]
  for line in result.stdout.splitOn "\n"do
    if line.startsWith "{" then
      objects := objects.push (← parseJson line "lean --json")
  return objects

/-- The value at `path` is absent or JSON null — the two spellings of "not captured". -/
private def ensureNull (json : Lean.Json) (path : List JsonStep) (label : String) : IO Unit := do
  match jsonAt? json path with
  | none =>
    pure ()
  | some .null =>
    pure ()
  | some other =>
    throw <| IO.userError s!"{label}: {other.compress}"

/-- Production capture, both gating directions, plus byte-stability of a second capturing run. -/
private def testCaptureGating (ctx : Ctx) : IO Unit := do
  let fixture := "tests/fixtures/semantic/Notation.lean"
  let setup ← setupFile ctx.root ctx.work fixture
  let on ← artifactOf (← capture ctx setup fixture "1" "capture on") "capture on"
  let off ← artifactOf (← capture ctx setup fixture "0" "capture off") "capture off"
  let on2 ← artifactOf (← capture ctx setup fixture "1" "capture on again") "capture on again"
  -- Both schemas advanced regardless of capture; only the semantic field differs. The version is
  -- read from the product rather than pinned: a schema bump this suite does not care about should
  -- not fail it. The cache suite owns whether a bump invalidates what it must.
  let onSchema := (on.getObjValAs? String "schema").toOption.getD ""
  ensureEq "capture changed the schema" ((off.getObjValAs? String "schema").toOption.getD "")
      onSchema
  ensure (onSchema.startsWith "lean-fmt.module-artifact.v") s!"unexpected schema {onSchema}"
  -- Demand-gating: no capture → semantic is null; capture → semantic present. The syntax
  -- projection is byte-identical either way, so the fact is purely additive.
  ensureNull off [.field "semantic"] "captureSemantic=0 still captured"
  ensure ((jsonAt? on [.field "semantic"]).isSome) "captureSemantic=1 produced no semantic fact"
  ensureEq "semantic capture perturbed the syntax projection"
      ((jsonAt? off [.field "syntaxData"]).getD .null).compress
      ((jsonAt? on [.field "syntaxData"]).getD .null).compress
  -- The artifact is byte-stable across identical runs.
  ensureEq "two identical capturing runs produced different artifacts" on.compress on2.compress
  let semanticKeys :=
    (((jsonAt? on [.field "semantic"]).bind (·.getObj?.toOption)).map fun node =>
          node.foldl (init := []) fun acc key _ => key :: acc).getD
      []
  ensureEq "semantic artifact: diagnostics/occurrences only" ["diagnostics"] semanticKeys

/-- `check` reaches no frontend at all when the facet is current: the source tier takes the
source-only shortcut, and the syntax tier is served from the facet. A disabled analyzer proves it —
either would exit 2 if it spawned one. Whether the facet and the frontend agree byte-for-byte is
the compiler suite's claim.

`format --check` is the other half, and it is stated as a refusal on purpose. It used to be served
from the facet too; that renderer was deleted after it measured slower than elaborating and
rejected files the frontend accepted. Rendering now has one route, so with no analyzer there is no
layout — and this case fails if the artifact renderer ever comes back without that being a
decision. -/
private def testFacetServes (ctx : Ctx) : IO Unit := do
  let clean := "tests/fixtures/check/Clean.lean"
  let env := #[("LEAN_FMT_TEST_ANALYZER", some "/usr/bin/false")]
  for (label, select) in [("source", #[]), ("syntax", #["--select", "FMT011"])]do
    let result ←
      runProc ctx.application
          (#["check", "--root", ".", "--json", "--no-cache"] ++ select ++ #[clean]) (cwd? :=
          some ctx.root) (env := env)
    ensureEq s!"check did not serve {label}-tier without a frontend" 0 result.exitCode
    ensure (!(result.stdout.contains "infrastructure-failure"))
        s!"check reached the disabled analyzer on the {label} tier"
  let fmtResult ←
    runProc ctx.application #["format", "--check", "--root", ".", "--json", "--no-cache", clean]
        (cwd? := some ctx.root) (env := env)
  ensureEq "format --check no longer needs a frontend to render" 2 fmtResult.exitCode
  let report ← parseJson fmtResult.stdout "facet format"
  ensureJsonAt report [.field "mode"] (Lean.toJson "format") "facet format"
  ensureJsonAt report [.field "written"] (Lean.toJson (0 : Nat)) "facet format"
  ensure (fmtResult.stdout.contains "infrastructure-failure")
      "format --check reported no failure yet reached no analyzer"

/-- The surfaced-diagnostics differential: the captured `(kind, range)` reproduces what Lean's
own `--json` frontend emits on the same fixture, for all four surfaced kinds. -/
private def testDiagnosticsDifferential (ctx : Ctx) : IO Unit := do
  let fixture := "tests/fixtures/semantic/Diagnostics.lean"
  let setup ← setupFile ctx.root ctx.work fixture
  let on ← artifactOf (← capture ctx setup fixture "1" "diag on") "diag on"
  let off ← artifactOf (← capture ctx setup fixture "0" "diag off") "diag off"
  let oracle ← leanOracle ctx fixture
  let source ← IO.FS.readFile (ctx.root / fixture)
  let captured :=
    (((jsonAt? on [.field "semantic", .field "diagnostics"]).bind (·.getArr?.toOption)).getD #[])
  -- Demand-gating: capture=0 carries no semantic fact at all (so no diagnostics either).
  ensureNull off [.field "semantic"] "capture=0 still captured diagnostics"
  let want :=
    ["Lean.Linter.deprecatedAttr", "linter.unusedVariables", "linter.unusedSectionVars",
      "linter.constructorNameAsVariable"]
  let gotKinds := captured.toList.map fun d => (d.getObjValAs? String "kind").toOption.getD ""
  for kind in want do
    ensure (gotKinds.contains kind) s!"missing surfaced kind: {kind}"
  for kind in gotKinds do
    ensure (want.contains kind) s!"captured unowned kind: {kind}"
  -- Every captured range is inside the module's own bytes and well-formed.
  for d in captured do
    let start := natAt? d [.field "range", .field "start"] |>.getD 0
    let stop := natAt? d [.field "range", .field "stop"] |>.getD 0
    ensure (start <= stop && stop <= source.utf8ByteSize) s!"range out of bounds: {d.compress}"
  -- Independent oracle: Lean's own positions, converted to byte offsets, must match a captured
  -- diagnostic of the same kind.
  let mut matched := 0
  for object in oracle do
    let kind := (object.getObjValAs? String "kind").toOption.getD ""
    if !want.contains kind then
      continue
    let line := natAt? object [.field "pos", .field "line"] |>.getD 0
    let col := natAt? object [.field "pos", .field "column"] |>.getD 0
    let start := byteOffset source line col
    let hit :=
      captured.any fun d =>
        (d.getObjValAs? String "kind").toOption == some kind &&
          (natAt? d [.field "range", .field "start"] |>.getD 0) == start
    ensure hit s!"no captured diagnostic matches oracle {kind} at byte {start}"
    matched := matched + 1
  ensure (matched >= 4) s!"oracle matched only {matched} diagnostics"
  IO.println s!"   diagnostics differential: matched {matched}"

/-- The owned occurrence fact, its differential, and its demand-gating: occurrences are captured
only under token "2", and the captured use resolves at the exact byte Lean's own deprecation
diagnostic points to. -/
private def testOccurrencesDifferential (ctx : Ctx) : IO Unit := do
  let fixture := "tests/fixtures/semantic/Diagnostics.lean"
  let setup ← setupFile ctx.root ctx.work fixture
  let semanticOnly ← artifactOf (← capture ctx setup fixture "1" "occ token 1") "occ token 1"
  let occurrences ← artifactOf (← capture ctx setup fixture "2" "occ token 2") "occ token 2"
  let oracle ← leanOracle ctx fixture
  let source ← IO.FS.readFile (ctx.root / fixture)
  -- Demand-gating, both directions. Lean's derived `ToJson` strips the trailing `?` from an
  -- Option field's name, so `occurrences?`/`newName?` serialize as `occurrences`/`newName`.
  ensureNull semanticOnly [.field "semantic", .field "occurrences"]
      "token 1 captured occurrences (info-tree walk not gated)"
  let some occ :=
    (jsonAt? occurrences [.field "semantic", .field "occurrences"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "token 2 captured no occurrences"
  ensure (!occ.isEmpty) "token 2 captured an empty occurrence list"
  -- The fixture's one deprecated USE is `def useOld : Nat := oldName`. The declaration site is a
  -- binder and must be excluded, so exactly the use is recorded.
  let uses :=
    occ.toList.filter fun o =>
      (((o.getObjValAs? String "declName").toOption.getD "").splitOn ".").getLast?.getD "" ==
        "oldName"
  let some use :=
    uses.head? | throw <| IO.userError s!"expected exactly one oldName use, got {uses.length}"
  ensureEq "oldName uses (binder excluded)" 1 uses.length
  let newName := ((use.getObjValAs? String "newName").toOption.getD "")
  ensure (((newName.splitOn ".").getLast?.getD "") == "newName") s!"unexpected newName {newName}"
  ensure (((use.getObjValAs? Bool "fixable").toOption).getD false)
      "a bare-identifier deprecated use must be fixable"
  -- The occurrence range spells exactly the identifier, and is NOT the declaration site.
  let start := natAt? use [.field "range", .field "start"] |>.getD 0
  let stop := natAt? use [.field "range", .field "stop"] |>.getD 0
  ensureEq "occurrence spelling" "oldName" (String.Pos.Raw.extract source ⟨start⟩ ⟨stop⟩)
  let declPos := ((source.splitOn "def oldName").head?.getD "").utf8ByteSize + "def ".utf8ByteSize
  ensure (start != declPos) "binder (declaration-site) occurrence was not excluded"
  -- Differential: the occurrence resolves at a byte Lean's own deprecation diagnostic points to.
  let starts :=
    oracle.toList.filter
        (fun o =>
          (o.getObjValAs? String "kind").toOption == some "Lean.Linter.deprecatedAttr") |>.map
      fun o =>
      byteOffset source (natAt? o [.field "pos", .field "line"] |>.getD 0)
        (natAt? o [.field "pos", .field "column"] |>.getD 0)
  ensure (!starts.isEmpty) "oracle emitted no deprecation diagnostic"
  ensure (starts.contains start)
      s!"occurrence at byte {start} does not match Lean's deprecation resolution {starts}"

/-- The fixable-occurrence predicate, adversarially: `fixable` only when the source spelling is
exactly the resolved constant's own full display name. A regression here is a soundness bug: a
wrong `fixable=true` would let `fix --unsafe-fixes` corrupt a dot-notation or `open`-shadowed
use. -/
private def testFixablePredicate (ctx : Ctx) : IO Unit := do
  let fixture := "tests/fixtures/semantic/Occurrences.lean"
  let setup ← setupFile ctx.root ctx.work fixture
  let artifact ← artifactOf (← capture ctx setup fixture "2" "fixable capture") "fixable capture"
  let source ← IO.FS.readFile (ctx.root / fixture)
  let some occ :=
    (jsonAt? artifact [.field "semantic", .field "occurrences"]).bind
      (·.getArr?.toOption) | throw <| IO.userError "no occurrences captured"
  let spelledOf (o : Lean.Json) : String :=
    let start := natAt? o [.field "range", .field "start"] |>.getD 0
    let stop := natAt? o [.field "range", .field "stop"] |>.getD 0
    String.Pos.Raw.extract source ⟨start⟩ ⟨stop⟩
  let checkOne (spelled : String) (wantFixable : Bool) (wantDecl : String) : IO Unit := do
    let some o :=
      occ.toList.find?
        (fun entry =>
          spelledOf entry == spelled) | throw <| IO.userError s!"no occurrence spelled {spelled}"
    let fixable := ((o.getObjValAs? Bool "fixable").toOption).getD false
    ensure (fixable == wantFixable)
        s!"occurrence {spelled} fixable={fixable}, expected {wantFixable}"
    let declName := (o.getObjValAs? String "declName").toOption.getD ""
    ensureEq s!"{spelled} declName" wantDecl declName
  -- Fixable: a bare top-level use, and a fully-qualified use whose whole span is the constant's
  -- own name.
  checkOne "oldBare" true "oldBare"
  checkOne "N.oldNs" true "N.oldNs"
  -- Report-only: the spelling is NOT the constant's full name -- a rename cannot be proven
  -- textually.
  checkOne "oldNs" false "N.oldNs"
  checkOne "oldGet" false "Wrap.oldGet"
  checkOne "oldNoRepl" false "oldNoRepl"
  -- No occurrence is fixable unless it carries a replacement name.
  for o in occ do
    let fixable := ((o.getObjValAs? Bool "fixable").toOption).getD false
    if fixable then
      ensure ((o.getObjValAs? String "newName").toOption.isSome)
          "an occurrence is fixable without a replacement name"

/-- The throwaway acceptance project: a clean library file so the package builds, and the
acceptance fixtures outside its glob so an intentionally-broken fixture never fails
`lake build`. -/
private def writeAcceptanceProject (proj : System.FilePath) (root : System.FilePath) : IO Unit := do
  IO.FS.createDirAll (proj / "acc")
  copyFile (root / "lean-toolchain") (proj / "lean-toolchain")
  writeFile (proj / "lakefile.lean")
      "import Lake\nopen Lake DSL\npackage \"ruff11acc\"\nlean_lib Demo where\n  roots := #[`Demo]\n  \
     globs := #[Glob.one `Demo]\n"
  writeFile (proj / "Demo.lean") "module\n\ndef demo : Nat := 1\n"
  -- Elaboration ERROR fixture (a type mismatch): `analyzeExact` returns `broken`.
  writeFile (proj / "acc" / "Broken.lean") "module\n\ndef bad : Nat := true\n"
  -- Mixed-tier fixture: a deprecated use (FMT012, semantic) AND a redundant nested paren (FMT011,
  -- syntax). FMT011 is a strictly cheaper tier than semantic FMT012, so `max` still lands on
  -- `.semantic`, and FMT011 also carries a safe fix for the pass-order case.
  writeFile (proj / "acc" / "Mixed.lean")
      "module\n\ndef newName : Nat := 1\n@[deprecated newName (since := \"2024-01-01\")]\n\
     def oldName : Nat := 0\ndef useOld : Nat := oldName\ndef parened : Nat := ((1))\n"

/-- End-to-end acceptance: error surfaced broken, mixed-tier selection,
withheld vs admitted owned fixes, `format` never renames, idempotence, and pass-order
independence. -/
private def testAcceptance (ctx : Ctx) : IO Unit := do
  let proj := ctx.work / "proj"
  writeAcceptanceProject proj ctx.root
  discard <|
      expectExit 0 "lake build Demo" "lake" #["-d", proj.toString, "build", "Demo"] (cwd? :=
        some ctx.root)
  let mixed := proj / "acc" / "Mixed.lean"
  let check (args : Array String) (expected : UInt32) (label : String) : IO Lean.Json := do
    let result ← expectExit expected label ctx.application args (cwd? := some ctx.root)
    parseJson result.stdout label
  -- 1. Silent-omission-on-error: a semantic selection over a file that fails to elaborate
  -- reports the file `broken`, never dropping it from `files`.
  let broken ←
    check
        #["check", "--root", proj.toString, "--json", "--no-cache", "--preview", "--select",
          "FMT012", (proj / "acc" / "Broken.lean").toString]
        1 "acc broken"
  let files := ((jsonAt? broken [.field "files"]).bind (·.getArr?.toOption)).getD #[]
  let statuses :=
    files.toList.map fun file =>
      ((file.getObjValAs? String "path").toOption.getD "",
        (file.getObjValAs? String "status").toOption.getD "")
  ensureEq "broken file omitted or mislabeled" [("acc/Broken.lean", "broken")] statuses
  ensureJsonAt broken [.field "broken"] (Lean.toJson (1 : Nat)) "acc broken"
  ensureJsonAt broken [.field "infrastructureFailures"] (.arr #[]) "acc broken"
  -- 2. Mixed-tier selection: both tiers' findings in one run.
  let mixedReport ←
    check
        #["check", "--root", proj.toString, "--json", "--no-cache", "--preview", "--select",
          "FMT011", "--select", "FMT012", mixed.toString]
        1 "acc mixed"
  let mixedFindings :=
    ((jsonAt? mixedReport [.field "files", .index 0, .field "findings"]).bind
          (·.getArr?.toOption)).getD
      #[]
  let codes := mixedFindings.toList.map fun f => (f.getObjValAs? String "code").toOption.getD ""
  ensure (codes.contains "FMT012") s!"mixed-tier lost the semantic finding: {codes}"
  ensure (codes.contains "FMT011") s!"mixed-tier lost the syntax finding: {codes}"
  let some dep :=
    mixedFindings.toList.find?
      (fun f =>
        (f.getObjValAs? String "code").toOption ==
          some "FMT012") | throw <| IO.userError "mixed-tier: no FMT012 finding"
  ensure (((dep.getObjValAs? String "message").toOption.getD "").toLower.contains "deprecated")
      "the semantic finding lost the compiler's own deprecation message"
  -- 3. Withheld (unadmitted) owned fix: FMT012's rename is `.unsafe`, so without
  -- `--unsafe-fixes` nothing publishes, and the withheld count records the omission.
  let original ← IO.FS.readFile mixed
  let withheld ←
    check
        #["fix", "--root", proj.toString, "--json", "--no-cache", "--preview", "--select", "FMT012",
          mixed.toString]
        0 "acc withheld"
  ensureJsonAt withheld [.field "written"] (Lean.toJson (0 : Nat)) "acc withheld"
  ensureJsonAt withheld [.field "changed"] (Lean.toJson (0 : Nat)) "acc withheld"
  let withheldCount := natAt? withheld [.field "withheldUnsafe"] |>.getD 0
  ensure (withheldCount >= 1) "an unsafe owned fix was not withheld"
  ensureEq "fix withholding an unsafe owned fix modified the source" original
      (← IO.FS.readFile mixed)
  -- 3b. Admitted owned fix applies a real rename at original-source coordinates.
  let applied ←
    check
        #["fix", "--root", proj.toString, "--json", "--no-cache", "--preview", "--unsafe-fixes",
          "--select", "FMT012", mixed.toString]
        0 "acc apply"
  ensureJsonAt applied [.field "written"] (Lean.toJson (1 : Nat)) "acc apply"
  ensureJsonAt applied [.field "changed"] (Lean.toJson (1 : Nat)) "acc apply"
  ensureJsonAt applied [.field "rejected"] (Lean.toJson (0 : Nat)) "acc apply"
  let renamed ← IO.FS.readFile mixed
  ensureContains renamed "def useOld : Nat := newName" "admitted fix did not rename"
  let useLine := (renamed.splitOn "\n").filter (·.contains "useOld")
  ensure (!(useLine.any (·.contains "oldName"))) "the deprecated name survives on the use line"
  -- The rename re-elaborates and leaves no deprecated use.
  let recheck ←
    check
        #["check", "--root", proj.toString, "--json", "--no-cache", "--preview", "--select",
          "FMT012", mixed.toString]
        0 "acc recheck"
  let recheckCodes :=
    (((jsonAt? recheck [.field "files", .index 0, .field "findings"]).bind
              (·.getArr?.toOption)).getD
          #[]).toList.map
      fun f => (f.getObjValAs? String "code").toOption.getD ""
  ensure (!(recheckCodes.contains "FMT012")) "the deprecated use survives the rename"
  -- 3b'. The inverse half: `format` owns no rule fix, so it never renames.
  let mixedFmt := proj / "acc" / "MixedFmt.lean"
  writeFile mixedFmt original
  let formatReport ←
    check
        #["format", "--check", "--root", proj.toString, "--json", "--no-cache", "--preview",
          "--unsafe-fixes", "--select", "FMT012", mixedFmt.toString]
        1 "acc format"
  match
    (jsonAt? formatReport [.field "files", .index 0, .field "formatted"]).bind
      (·.getStr?.toOption) with
  | some out =>
    ensure (out.contains "oldName" && !(out.contains "def useOld : Nat := newName"))
        "format applied the FMT012 rename -- it must not"
  | none =>
    pure ()
  ensureContains (← IO.FS.readFile mixedFmt) "def useOld : Nat := oldName"
      "format mutated the deprecated use"
  IO.FS.removeFile mixedFmt
  -- 3c. Idempotence: a second fix over the renamed file is a no-op.
  let fixedBytes ← IO.FS.readFile mixed
  let idem ←
    check
        #["fix", "--root", proj.toString, "--json", "--no-cache", "--preview", "--unsafe-fixes",
          "--select", "FMT012", mixed.toString]
        0 "acc idem"
  ensureJsonAt idem [.field "written"] (Lean.toJson (0 : Nat)) "acc idem"
  ensureJsonAt idem [.field "changed"] (Lean.toJson (0 : Nat)) "acc idem"
  ensureEq "a second FMT012 fix modified an already-renamed file" fixedBytes
      (← IO.FS.readFile mixed)
  -- 3d. Pass-order independence: FMT012 and FMT011 compose the same either way.
  let orderA := proj / "acc" / "OrderA.lean"
  let orderB := proj / "acc" / "OrderB.lean"
  writeFile orderA original
  writeFile orderB original
  discard <|
      check
        #["fix", "--root", proj.toString, "--json", "--no-cache", "--preview", "--unsafe-fixes",
          "--select", "FMT012", "--select", "FMT011", orderA.toString]
        0 "order A"
  discard <|
      check
        #["fix", "--root", proj.toString, "--json", "--no-cache", "--preview", "--unsafe-fixes",
          "--select", "FMT011", "--select", "FMT012", orderB.toString]
        0 "order B"
  ensureEq "pass order changed the published bytes" (← IO.FS.readFile orderA)
      (← IO.FS.readFile orderB)
  ensureContains (← IO.FS.readFile orderA) "def useOld : Nat := newName"
      "order-independent fix did not apply the rename"
  IO.FS.removeFile orderA
  IO.FS.removeFile orderB
  writeFile mixed original

/-- Cost: the info-tree walk is the demanded delta the capability split
bounds. Peak RSS and wall time across the three capture levels, best-effort under
`/usr/bin/time -l` (Darwin); the source projection is already proven byte-identical either way. -/
private def testCost (ctx : Ctx) : IO Unit := do
  let probe ← runProc "/usr/bin/time" #["-l", "true"]
  if probe.exitCode != 0 then
    IO.println "   cost: /usr/bin/time -l unavailable -- RSS/wall additivity check skipped"
    return
  let fixture := "tests/fixtures/semantic/Diagnostics.lean"
  let setup ← setupFile ctx.root ctx.work fixture
  let measure (token : String) : IO String := do
    -- `/usr/bin/time -l` writes its stats to the child's stderr.
    let timed ←
      runProc "/usr/bin/time"
          #["-l", "lake", "env", ctx.application, "__analyze-exact", setup.toString, fixture,
            fixture, token]
          (cwd? := some ctx.root)
    return timed.stderr
  let rssOf (stats : String) (label : String) : IO Nat := do
    for line in stats.splitOn "\n"do
      if line.contains "maximum resident set size" then
        match ((line.splitOn " ").filter (!·.isEmpty)).head?.bind String.toNat? with
        | some n =>
          return n
        | none =>
          throw <| IO.userError s!"{label}: unparsable RSS line {line}"
    throw <| IO.userError s!"{label}: no RSS line"
  let realOf (stats : String) (label : String) : IO Float := do
    for line in stats.splitOn "\n"do
      if line.contains " real" then
        match ((line.splitOn " ").filter (!·.isEmpty)).head? with
        | some word =>
          match word.splitOn "." with
          | [whole, frac] =>
            match whole.toNat?, frac.toNat? with
            | some w, some f =>
              return w.toFloat + f.toFloat / (10.0 : Float) ^ frac.length.toFloat
            | _, _ =>
              throw <| IO.userError s!"{label}: unparsable real line {line}"
          | [whole] =>
            match whole.toNat? with
            | some w =>
              return w.toFloat
            | none =>
              throw <| IO.userError s!"{label}: unparsable real line {line}"
          | _ =>
            throw <| IO.userError s!"{label}: unparsable real line {line}"
        | none =>
          throw <| IO.userError s!"{label}: unparsable real line {line}"
    throw <| IO.userError s!"{label}: no real line"
  let off ← measure "0"
  let on ← measure "1"
  let occ ← measure "2"
  let offRss ← rssOf off "off"
  let onRss ← rssOf on "on"
  let occRss ← rssOf occ "occ"
  let onReal ← realOf on "on"
  let occReal ← realOf occ "occ"
  let gib : Nat := 8 * 1024 ^ 3
  ensure (onRss < gib) s!"capture-on peak RSS {onRss} exceeds the 8 GiB envelope"
  -- Additive: capturing the already-collected MessageLog must not multiply memory. 1.5x is
  -- generous headroom over the observed ~parity.
  ensure (onRss <= offRss * 3 / 2) s!"capture-on RSS {onRss} ballooned over capture-off {offRss}"
  ensure (occRss < gib) s!"occurrence-capture peak RSS {occRss} exceeds the 8 GiB envelope"
  ensure (occRss <= offRss * 3 / 2)
      s!"occurrence capture RSS {occRss} ballooned over capture-off {offRss}"
  ensure (occReal <= onReal * 2 + 0.5)
      s!"occurrence walk wall time {occReal}s ballooned over surfaced-only {onReal}s"
  IO.println
      s!"   cost: RSS diag-capture {onRss / 1048576} MiB, occ-capture \
    {occRss / 1048576} MiB vs off {offRss / 1048576} MiB; wall surfaced {onReal}s vs walk \
    {occReal}s (fold is a read)"

end Semantic

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  -- Refresh the Clean fixture's artifact facet: a schema bump changes the compiler plugin, so a
  -- stale on-disk artifact is correctly rejected by the schema guard.
  discard <|
      expectExit 0 "lake build lean-fmt Clean:leanFmtArtifact" "lake"
        #["build", "lean-fmt", "Clean:leanFmtArtifact"] (cwd? := some root)
  withTempDir fun work => do
      let ctx : Semantic.Ctx :=
        { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work }
      let cases : Array Case :=
        #[{ name := "capture-gating", run := Semantic.testCaptureGating ctx },
          { name := "facet-serves", run := Semantic.testFacetServes ctx },
          { name := "diagnostics-differential", run := Semantic.testDiagnosticsDifferential ctx },
          { name := "occurrences-differential", run := Semantic.testOccurrencesDifferential ctx },
          { name := "fixable-predicate", run := Semantic.testFixablePredicate ctx },
          { name := "acceptance", run := Semantic.testAcceptance ctx },
          { name := "cost", run := Semantic.testCost ctx }]
      runCases "semantic" cases args
