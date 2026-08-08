module

public import Test

/-!
# The catalog suite

Executable-example acceptance. Every live rule's documented example is not decoration: it is *run*
against the real product. Sourced from the registry (`explain CODE --json`, the one metadata object
the docs are also generated from), the suite proves for each rule with examples that:

- the `bad` snippet, run through the exact frontend, reports exactly that rule (no more, no less,
  no infrastructure failure);
- a fixable rule's `fix` rewrites `bad` into its `good` byte-for-byte, and a re-check is silent
  (the fix is idempotent);
- a report-only rule's `good` (when shown) is itself clean for that rule.

It also pins the CLI lifecycle contract (`explain` on a live / meta / unknown code) and the
generated-docs drift check (`docs --check`), so a metadata edit that forgets to regenerate the
pages fails here, and the generated-tree link check.

Snippets omit the private-module `module` header for readability; the suite prepends it before
running. Preview rules are unlocked with `--preview`, exactly the gate a user hits. Every example
goes through the exact frontend (artifact and module evidence disabled), matching the syntax
suite. Example probes live under `tests/.scratch` (still under the project root, as `fix`
requires) instead of the old in-tree `.probe-*` dotfiles the trap cleaned.

Lane: workspace — the suite clears the root cache and `fix` populates it.
-/

open LeanFmt.Test
open LeanFmt.Test.Analyze

namespace Catalog

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath

private def fallbackEnv : Array (String × Option String) :=
  #[("LEAN_FMT_DISABLE_ARTIFACT", some "1"), ("LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE", some "1")]

/-- A snippet becomes a module-system source: `module` header, one trailing newline. -/
private def wrap (body : String) : String :=
  let trimmed := ((body.trimAsciiEnd).toString)
  "module\n" ++ trimmed ++ "\n"

/-- The relative-from-root path of a scratch probe, for `--root .` invocation. -/
private def rel (ctx : Ctx) (path : System.FilePath) : String :=
  String.Pos.Raw.extract path.toString ⟨ctx.root.toString.utf8ByteSize + 1⟩
    ⟨path.toString.utf8ByteSize⟩

private def explainJson (ctx : Ctx) (code : String) : IO Lean.Json := do
  let result ←
    expectExit 0 s!"explain {code} --json" ctx.application #["explain", code, "--json"] (cwd? :=
        some ctx.root)
  parseJson result.stdout s!"explain {code}"

private def runFallback (ctx : Ctx) (expected : UInt32) (args : Array String) (label : String) :
    IO ProcResult :=
  expectExit expected label ctx.application args (cwd? := some ctx.root) (env := fallbackEnv)

/-- The executable-example battery across the whole registry. -/
private def testExamples (ctx : Ctx) : IO Unit := do
  let rulesJson ←
    expectExit 0 "rules --json" ctx.application #["rules", "--json"] (cwd? := some ctx.root)
  let some rules :=
    ((←
        parseJson rulesJson.stdout
            "rules").getArr?.toOption) | throw <| IO.userError "rules --json is not an array"
  let sorted :=
    rules.qsort fun a b =>
      ((a.getObjValAs? String "code").toOption.getD "") <
        ((b.getObjValAs? String "code").toOption.getD "")
  -- Findings not expressible as a self-contained snippet.
  let exempt := ["FMT001", "FMT002", "FMT004"]
  let mut tested := 0
  for rule in sorted do
    let code := (rule.getObjValAs? String "code").toOption.getD ""
    let info ← explainJson ctx code
    let examples := ((jsonAt? info [.field "examples"]).bind (·.getArr?.toOption)).getD #[]
    let stable := (info.getObjValAs? String "lifecycle").toOption == some "stable"
    let preview := if stable then #[] else #["--preview"]
    if exempt.contains code then
      ensure examples.isEmpty s!"{code}: example-exempt rule carries an example"
      continue
    ensure (!examples.isEmpty) s!"{code}: live non-exempt rule has no executable example"
    let fixable := (info.getObjValAs? Bool "fixable").toOption.getD false
    for index in [0:examples.size]do
      let tag := s!"{code}-{index}"
      let probe := ctx.work / s!"probe-{tag}.lean"
      let relative := rel ctx probe
      let entry := examples[index]!
      let bad := (entry.getObjValAs? String "bad").toOption.getD ""
      writeFile probe (wrap bad)
      -- The `bad` snippet reports exactly this rule and nothing else.
      let report ←
        runFallback ctx 1
            (#["check", "--root", ".", "--json", "--no-cache"] ++ preview ++
              #["--select", code, relative])
            tag
      let data ← parseJson report.stdout tag
      let files := ((jsonAt? data [.field "files"]).bind (·.getArr?.toOption)).getD #[]
      ensureEq s!"{tag}: files" 1 files.size
      let got :=
        (((jsonAt? files[0]! [.field "findings"]).bind (·.getArr?.toOption)).getD #[]).map
          fun finding => (finding.getObjValAs? String "code").toOption.getD ""
      ensureEq s!"{tag}: bad example reported the wrong codes" [code] got.toList
      ensureJsonAt data [.field "infrastructureFailures"] (.arr #[]) tag
      ensureJsonAt data [.field "broken"] (Lean.toJson (0 : Nat)) tag
      let good? := (entry.getObjValAs? String "good").toOption
      match good? with
      | none =>
        tested := tested + 1
      | some good =>
        if fixable then
          -- `fix` rewrites `bad` into `good`, byte-for-byte after the shared `module` wrap.
          -- `--unsafe-fixes` admits both safe and unsafe fixes, so an example's `good` is the
          -- fully fixed form regardless of the rule's applicability.
          discard <|
              runFallback ctx 0
                (#["check", "--fix", "--root", ".", "--json", "--no-cache", "--unsafe-fixes"] ++
                  preview ++
                  #["--select", code, relative])
                tag
          let produced ← IO.FS.readFile probe
          ensureEq s!"{tag}: fix output != good example" (wrap good) produced
          -- Idempotent: a re-check of the written file is silent for this rule.
          let recheck ←
            runFallback ctx 0
                (#["check", "--root", ".", "--json", "--no-cache"] ++ preview ++
                  #["--select", code, relative])
                tag
          ensureJsonAt (← parseJson recheck.stdout tag) [.field "findings"] (Lean.toJson (0 : Nat))
              s!"{tag}: fix not idempotent"
        else
          -- A report-only rule may still *show* the corrected form; it must itself be clean.
          writeFile probe (wrap good)
          let report ←
            runFallback ctx 0
                (#["check", "--root", ".", "--json", "--no-cache"] ++ preview ++
                  #["--select", code, relative])
                tag
          let got :=
            (((jsonAt? (← parseJson report.stdout tag)
                          [.field "files", .index 0, .field "findings"]).bind
                      (·.getArr?.toOption)).getD
                  #[]).map
              fun finding => (finding.getObjValAs? String "code").toOption.getD ""
          ensureEq s!"{tag}: good example still reports" ([] : List String) got.toList
        tested := tested + 1
  IO.println s!"   executed {tested} registry examples across {sorted.size} live rules"

/-- `explain` answers for every class of code the product can print: a live rule explains with
exit 0; a meta self-diagnostic (FMT900/FMT901) explains its description (exit 0) though it is in
neither table, because it is never selectable. Only a code the product could never have emitted is
an error. Absence from the registry is a fact about *selection*, not about existence. -/
private def testExplainLifecycle (ctx : Ctx) : IO Unit := do
  let expectations : Array (String × UInt32 × String) :=
    #[("FMT001", 0, "FMT001"), ("FMT900", 0, "suppressed nothing"),
      ("FMT901", 0, "does not parse as a directive"), ("FMT999", 2, "")]
  for (code, expected, needle) in expectations do
    let result ← runProc ctx.application #["explain", code] (cwd? := some ctx.root)
    ensureEq s!"explain {code}: exit" expected result.exitCode
    unless needle.isEmpty do
      ensureContains (result.stdout ++ result.stderr) needle s!"explain {code}"

/-- Generated-docs drift: the pages regenerate identically from the registry. -/
private def testDocsCheck (ctx : Ctx) : IO Unit := do
  discard <|
      expectExit 0 "docs --check" ctx.application #["docs", "--check"] (cwd? := some ctx.root)

/-- Documentation link check: every relative link in the generated tree resolves,
every live rule has a page, and the index links each one. -/
private def testDocLinks (ctx : Ctx) : IO Unit := do
  let docsDir := ctx.root / "docs" / "rules"
  let rulesJson ←
    expectExit 0 "rules --json" ctx.application #["rules", "--json"] (cwd? := some ctx.root)
  let codes :=
    (((← parseJson rulesJson.stdout "rules").getArr?.toOption).getD #[]).filterMap fun rule =>
      (rule.getObjValAs? String "code").toOption
  let index ← IO.FS.readFile (docsDir / "index.md")
  -- Every relative markdown link target in the index exists on disk: scan for `](target)`.
  let mut rest := index
  while true do
    match rest.splitOn "](" with
    | _ :: tail :: _ =>
      let target := (tail.splitOn ")").head?.getD ""
      unless target.startsWith "http://" || target.startsWith "https://" || target.startsWith "#" do
        ensure (← (docsDir / target).pathExists) s!"index links a missing file: {target}"
      rest := tail
    | _ =>
      break
  -- Every live rule has a page and the index links it.
  for code in codes do
    ensure (← (docsDir / s!"{code}.md").pathExists) s!"no page for live rule {code}"
    ensure (index.contains s!"({code}.md)") s!"index does not link {code}"
  -- The generated config schema is referenced and present.
  ensure (← (docsDir / "schema.json").pathExists) "schema.json missing"
  ensure (index.contains "schema.json") "index does not mention schema.json"
  IO.println s!"   doc links OK: {codes.size} rule pages, index + schema resolve"

end Catalog

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  removeDirAll? (root / ".lean-fmt-cache")
  withScratchDir "catalog" fun work => do
      let ctx : Catalog.Ctx :=
        { root, application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString, work }
      let cases : Array Case :=
        #[{ name := "executable-examples", run := Catalog.testExamples ctx },
          { name := "explain-lifecycle", run := Catalog.testExplainLifecycle ctx },
          { name := "docs-check", run := Catalog.testDocsCheck ctx },
          { name := "doc-links", run := Catalog.testDocLinks ctx }]
      runCases "catalog" cases args
