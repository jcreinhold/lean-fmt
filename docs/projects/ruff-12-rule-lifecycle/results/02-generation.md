---
claim_id: RRL-IMPL
status: verified
---

# RRL-IMPL — registry-derived CLI and docs

Implements `notes/01-schema.md` §12's RRL-IMPL contract: lifecycle-aware selection, fixability
configuration, `explain`, the generated rule pages/index/config-schema, and executable examples sourced
from the registry. One metadata source (`RuleInfo` + the reserved table) now projects to every surface —
`rules`, `explain`, `docs/rules/*`, and the `lean-fmt.toml` schema — so they cannot disagree.

## What shipped

- **`RuleInfo` (`LeanFmt/Rules.lean`).** New `Lifecycle = stable | preview | deprecated` (with `toWire`
  and JSON instances) and fields `lifecycle`, `explanation`, `examples : Array RuleExample`
  (`bad`/`good?`), `replacement?`. All 15 live rules (FMT003–017) and the 3 import identities carry
  lifecycle + explanation + a populated example (except the three example-exempt, below). Reserved table
  `reservedCodes` (FMT001/FMT002) with `isReservedCode`/`reservedDisposition?`.
- **Preview gate + specificity precedence (`LeanFmt/Config.lean`).** `RulePlan` resolution over a new
  `CliSelection`: `all`/`default`/category expand to stable rules only unless `--preview`/`preview =
  true`; an explicit preview-code selection without the gate is a specific error (exit 2). Precedence is
  ruff specificity (exact > category > `all`/`default`; tie → ignore), layered across config/CLI. The
  gate/precedence live entirely in the plan projection — never `runRules`, the cache key, or fact
  acquisition.
- **Fixability axis (`Config.lean`, `Application.lean`).** `fixable`/`unfixable`/`extend-fixable` select
  which selected rules' fixes `fix` applies, orthogonal to selection and to safe/unsafe applicability.
  Emitted `plan.notices` (preview/retired) print to stderr from `Application`/`Service`.
- **`explain` + `docs` (`LeanFmt/Cli.lean`).** `explain CODE [--json]` presents one `RuleInfo` (live →
  exit 0; retired → disposition, exit 0; unknown/meta → exit 2). `docs [--check]` writes/verifies
  `docs/rules/`. `rules` gained the lifecycle column.
- **Generated output (`Rules.lean`, drift-checked).** `catalogDocs` = `index.md` + `schema.json` +
  15 `FMT###.md` pages. Each page opens with **YAML frontmatter** (`code`/`category`/`tier`/`lifecycle`/
  `fix`/`default`/`replacement`) so a tool parses the catalog straight from the pages; `schema.json` is a
  JSON-schema fragment for `lean-fmt.toml` whose `selector` enum is `selectorVocabulary`, the same set
  `selectorsValid` accepts (they can't drift).
- **Tests.** `testCatalogInvariants` (`LeanFmtTest.lean`) — code shape/uniqueness, category/lifecycle
  coherence, doc-count, example-exempt handling, reserved integrity, schema-vocabulary coverage.
  `tests/catalog/run.sh` — executable examples: every non-exempt rule's `bad` fires exactly that rule
  through the exact frontend, every fixable rule's `fix` rewrites `bad` into `good` byte-for-byte and is
  idempotent, report-only `good`s are clean, plus the `explain` class contract and `docs --check`.

## Commands and evidence

```
$ LEAN_NUM_THREADS=1 lake build                      # 45 jobs, success
$ lake exe lean-fmt-tests                             # "lean-fmt module-artifact tests passed"
$ tests/catalog/run.sh                                # executed 12 registry examples across 15 live rules; passed
$ tests/boundary/run.sh                               # Rules.lean stays out of the plugin closure; passed
$ tests/syntax/run.sh   tests/semantic/run.sh         # passed (updated to pass --preview)
$ tests/modes/run.sh    tests/check/run.sh            # passed
$ tests/suppression/run.sh                            # passed (updated to pass --preview)
$ tests/service/run.sh  tests/lossless/run.sh  tests/compiler/run.sh   # passed
$ tests/scale/run.sh                                  # passed (exit 0)
```

Behavioral evidence (this tree):

```
$ lean-fmt rules | head
FMT003  security  stable   report-only  default   reject forbidden control bytes in source
FMT008  docs      preview  report-only  optional  require a module docstring when a module declares anything
FMT010  redundancy preview fixable      optional  remove a duplicate attribute in an attribute list

$ lean-fmt check --select FMT013 tests/check/Findings.lean ; echo $?
lean-fmt: rule FMT013 is in preview; enable preview mode (--preview) to select it
2

$ lean-fmt check --select FMT001 tests/check/Findings.lean   # stderr
lean-fmt: selector FMT001 names no live rule (retired: line-boundary normalization is now part of canonical formatting; run `format`)

$ lean-fmt explain FMT999 ; echo $?      # unknown/meta → specific error
2

$ ls docs/rules/
FMT003.md … FMT017.md  index.md  schema.json     # 17 files, `docs --check` clean
```

Full-catalog baseline capture is `evidence/01-schema-catalog.md` (from RRL-SPEC); the wire additions
(`lifecycle` on `rules --json`, `explanation`/`examples` on `explain --json`) are additive over it.

## Decisions changed during execution

1. **YAML frontmatter on rule pages** (added mid-implementation, at the maintainer's request). Each
   `FMT###.md` opens with a frontmatter block carrying the machine-readable axes, so a tool parses the
   catalog without re-deriving them; the visible body repeats the facts for a human. Recorded in schema
   note §9.
2. **`schema.json` config-schema fragment.** §11/§12 call for a generated JSON-schema fragment for
   `lean-fmt.toml` "beside the rule docs." Delivered as `catalogSchemaJson`, source-true against
   `parseConfig`'s key set (`Config.lean:182–201`) and `selectorsValid`'s vocabulary, and drift-checked
   like every page.
3. **Two false examples caught by the executable harness and corrected — the harness's whole point.**
   - **FMT014** originally used `@[deprecated "use new" …]`, a *message-string* form that sets no
     `newName?`, so the promised rename fix could never fire. Corrected to the identifier form
     `@[deprecated new …]` (matching `tests/semantic/Diagnostics.lean`); the `fix --unsafe-fixes` rename
     `old → new` now runs and is idempotent.
   - **FMT016**'s example (`variable (n : Nat)` unused in `theorem triv : True`) did not trigger
     `linter.unusedSectionVars` — an unreferenced section variable is simply not auto-included.
     Corrected to the canonical unused-instance-binder form (`variable {α} [inst : Inhabited α]` with a
     theorem using `α` but not `inst`), which fires.
4. **Example-exempt set {FMT003, FMT004, FMT006}.** Their findings (forbidden control bytes,
   bidirectional-control glyphs, cross-module import-graph facts) are not expressible as a self-contained
   snippet; the invariants test asserts these carry no example, and the harness skips them (recorded in
   schema note §10, §13).
5. **Suites now pass `--preview` where they select preview rules** (syntax, semantic, modes, check,
   suppression) — the intended behavior change from the preview gate, modeling what a real user does.
   `modes`' preview references are metadata assertions only and needed no change.

## Remaining uncertainty / deferred to RRL-FINAL

- No FMT008–FMT017 rule is promoted to stable or default-on here; promotion is RRL-FINAL's decision on
  reviewed frozen-sample precision (schema note §4, §12).
- `explain`/`docs --check` do not flag a *stray* extra file in `docs/rules/` (they verify each generated
  file matches); the "undocumented rule" direction is covered, the "orphan file" direction is not. Left
  as-is — low value, and no generator writes orphans.
- `docs --check` drift and the full precedence/migration/suppression matrices are re-run as RRL-FINAL's
  acceptance, not just RRL-IMPL's smoke coverage.
