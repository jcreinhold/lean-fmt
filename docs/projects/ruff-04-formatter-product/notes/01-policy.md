# Formatting policy and CLI semantics

`RFP-SPEC`. This freezes what `lean-fmt` promises about layout: the style guide, the configuration
schema, the command truth table, exit behavior, and how formatting composes with lint rules. It
changes no product behavior. `RFP-IMPL` does that, and this note is what it must implement against.

## 1. The boundary today: `format` does not format

The command named `format` previews the fixes of selected lint rules. It never consults layout.

`evidence/01-format-does-not-format.txt` is the transcript. `tests/check/Layout.lean` is lint-clean
and holds `namespace     Alpha` — five spaces where `LeanFmt.Printer` renders exactly one. `format`
reports it `"status":"clean"`, `changed=0`, `formatted:null`, exit 0.

Three independent facts put the printer out of reach, and they compound:

1. **Nothing calls it.** `LeanFmt.Printer` is imported by `LeanFmtTest.lean` and by nothing else. It
   *is* compiled into `LeanFmtCore` (`lakefile.lean:51-63`) and is reachable from the application —
   its absence from the plugin library is a separate, correct decision ("layout is a consumer of the
   projection, never a producer of it", `lakefile.lean:42-50`). This is not a packaging problem.
2. **Its input is never built.** Both registry rules are `input := .source` (`Rules.lean:29,37`), so
   `RulePlan.requiresSyntax` is `false` (`Config.lean:199-200`), so `officialArtifacts` is never
   invoked (`Application.lean:569`). No syntax tree is constructed in a default run. The printer
   takes a projection; the product does not make one.
3. **The preview path has nowhere to put it.** `prepareFile` takes `(plan, snapshot, analysis)` and
   `PreparedFile` holds `findings, normalized, lineEndings, patch` (`Application.lean:423-443`).
   Source bytes and findings. No projection, no tree.

Fact 3 is the one with teeth, because of the cache. `SemanticResult` is
`{schema, source, sourceBytes, findings}` (`Semantic.lean:7-12`) — findings only. And a full cache
hit returns straight from `previewFile` (`Application.lean:557-563`), *before* `officialArtifacts`
at `:569` is reached. So on a cache hit there is no tree and no way to build one without discarding
the hit. **This is the integration problem `RFP-IMPL` owns**, and §7 states the constraint it must
respect.

## 2. Style guide

The canonical layout is `LeanFmt.Printer` as `RLF-FINAL` left it. It is not restated here, because a
prose copy would drift from the code; `notes/01-command-printing.md` in `ruff-03-language-formatting`
is the design and `LeanFmt/Printer.lean` is the authority. The policy is its shape:

- **A layout applies only where the grammar declares the answer.** One space between two tokens of a
  claimed flat run where the grammar declares no atom; the declared string where it declares one
  (`" : "`, `" := "`, `" => "`, `"| "`); a docstring and an attribute block each end their line.
- **Everything else keeps its bytes.** A kind with no cited layout is `verbatim`. This is the default
  and it is why the printer is safe to run on code nobody wrote to suit it.
- **The header is the one vertical decision.** Keep the author's blank line, collapse runs to one,
  add one after `module`.

The consequence worth naming: **on canonical input the printer is the identity at every margin**,
checked at 0, 1, 40, 80, 120, and 1000 over this repository's own corpus
(`LeanFmtTest.lean:831-836`). On the frozen mathlib sample it changes 12 of 62 modules and every
change round-trips to the same tokens and comments (`ruff-03 evidence/01-printer-sample.txt`).

## 3. Configuration schema

**The stable style surface is empty.** No style key is exposed, and none is added by `RFP-IMPL`.

This is a refusal with evidence, not a deferral. The roadmap permits "line width, indentation
style/width, line ending policy, and explicitly justified language options" and adds "avoid a knob
for every layout decision". Read as a cap on the maximum surface rather than a list of things to
ship, since "explicitly justified" is the standard throughout. Taken one at a time:

| candidate | status | why |
| --- | --- | --- |
| `line-width` | **refused** | The margin is never read. See below. |
| `indent-style`, `indent-width` | **refused** | The printer emits no `nest`; its only indentation is column 0. `RLF-EXTENSIONS` refused re-indentation on grammar grounds — `nest` cannot move a `.keep` gap, and a collapse that moves a column another line is measured against is unsafe. A knob would have nothing to steer. |
| `line-ending` | **frozen as "preserve", not exposed** | Real, and already decided: `LosslessSource.normalize`/`denormalize` round-trips each file to its own form (`Application.lean:429-431`). This is the safest policy and the lossless layer already guarantees it. An override would change bytes and would therefore need cache identity (§7); nothing has asked for one. |
| language options | **none** | None is justified today. |

**Why `line-width` is refused, precisely.** `Printer.format` requires a `width` (`Printer.lean:1528`)
rather than defaulting it, so `RFP-IMPL` must pass a value. That value is unobservable:

- `Doc.go` threads `w` through every constructor and *reads* it at exactly one place — the
  `.group`/`.brk` case, `if fits (w - col) ...` (`Doc.lean:219-229`). `.text`, `.verbatim`, `.cat`,
  `.nest`, `.mark`, `.hard`, and `.line` all pass it through untouched.
- `LeanFmt/Printer.lean` emits exactly three constructors: `Doc.text`, `Doc.hard`, `Doc.verbatim`.
  No `group`, no `line`, no `nest` — grep the file.

No group means `fits` is never called means `w` is never read. **Every margin produces identical
bytes, for foreign input as much as canonical.** The six-margin test corroborates this on canonical
input; the structural argument is what proves it in general.

So a `line-width` knob would be a control that cannot change a byte — a fake shim, and this stack's
loop stops for those. `RFP-IMPL` passes a value internally; **100** is the choice, matching mathlib's
own convention, and it is a constant rather than a key. It is not in cache identity because it
changes no output (§7).

**The exact trigger that reverses each refusal.** `line-width` becomes real the day a layout emits a
`group` — that is, when a wrapping decision exists to make. `indent-*` becomes real the day a layout
emits a `nest`. Both are `RLF`-side events, not product-side ones, and neither has happened. Whoever
adds the first `group` to `Printer.lean` adds the key **and** its cache-identity component in the
same commit; §7 says why the order is not optional.

## 4. Command truth table

`format` and `diff` are the two commands whose meaning `RFP-IMPL` changes. Today's column is pinned
by `tests/modes/run.sh`.

| command | writes source | today | after `RFP-IMPL` |
| --- | --- | --- | --- |
| `check` | never | lists findings | **unchanged** — findings, not layout |
| `format` | never | previews lint fixes | previews canonical layout **and** lint fixes |
| `diff` | never | diffs lint fixes | diffs canonical layout **and** lint fixes |
| `fix` | **yes, sole writer** | applies lint fixes | applies both, one atomic validated patch |
| `rules`, `clean`, `serve`, `compiler` | never | — | unchanged |

`check` not moving is the load-bearing row. Formatting is a canonical transformation, not a
selectable rule, so it does not enter rule selection — and `check` reports *selected rules*. A file
that is badly laid out but lint-clean is `check`-clean before and after. That is the contract's first
bullet, and it is also what makes the migration in §8 work.

## 5. Exit behavior

Unchanged; `RFP-IMPL` adds no code. From `reportExitCode` (`Cli.lean`):

| exit | condition |
| --- | --- |
| **2** | `infrastructureFailures` is non-empty — the tool could not answer |
| **1** | `broken > 0 \|\| rejected > 0` — a file could not be analyzed or its patch was refused |
| **1** | `mode != .fix && changed > 0` — a preview mode found work to do |
| **0** | otherwise |

Two properties worth stating because they are easy to break later:

- **`fix` exits 0 when it changed files.** It did the work; there is nothing to report. Only the
  preview modes exit 1 on `changed > 0`.
- **Exit 2 is never "your code is bad".** It is reserved for the tool failing, which is what lets CI
  distinguish a finding from an outage.

`RFP-IMPL` widens what `changed > 0` *means* for `format` and `diff` — layout now counts — without
touching the table. That is a behavior change routed through data, not control flow, which is the
cheapest form this could take.

## 6. Formatter/linter interaction

The contract requires composition "without duplicate edits or order-dependent output".

- **Formatting is not a rule.** It has no code, cannot be `--select`ed or `--ignore`d, and does not
  appear in `rules`. It is not `FMT003`.
- **Both rules today are `category := "text"` and `input := .source`** — trailing whitespace and
  final newline. Neither is a layout decision; both are decisions about bytes the printer's `Doc`
  model does not even represent (`Doc.text` "must not contain `'\n'`").
- **The rules are not subsumed by canonical text. I checked, and my first answer was wrong.** I
  expected the printer to emit no trailing whitespace and to terminate the file, making both fixes
  no-ops on canonical text. It does neither. Given `def v : Nat := 1··` with no final newline, the
  printer returns `namespace     Alpha` → `namespace Alpha` **and leaves both violations in place**
  (`evidence/02-canonical-text-still-lints.txt`). That is not a defect: `··` is the trailing trivia
  run of the last token of its command, and a command's extent keeps its own trailing run verbatim
  (`Printer.lean:208-222`). The printer is a layout engine; whitespace at end-of-line is not a layout
  decision it makes. So FMT001 and FMT002 remain live after formatting, and both edits still apply.
- **The real hazard is stale offsets, not duplicate edits.** Findings index the normalized source
  (`Application.lean:420-422`). Canonicalizing `namespace     Alpha` deletes four bytes, so *every*
  finding offset past that point is wrong against canonical text. A cached FMT001 finding applied to
  formatted text lands four columns off and corrupts the file. This is the same coordinate argument
  the CRLF comment already makes, one layer up, and it is sharper than the contract's "duplicate
  edits" phrasing: nothing is duplicated, the edit is simply misplaced.
- **Therefore the composition is fixed: format first, then re-derive findings against the canonical
  text.** Not reuse. `RFP-IMPL` cannot apply the findings it already has to text it just rewrote, and
  it cannot reorder — fixing first and formatting second re-runs the layout over patched bytes and
  has the same problem mirrored. This constrains the cache directly (§7): the cached findings index
  the *original* source, and are unusable for a `fix` that also formats.
- **Duplicate edits remain possible in general and nothing would catch one.** An FMT rule that *did*
  overlap a layout decision would produce exactly what the contract forbids. Today none does — both
  rules are `category := "text"`, about bytes the `Doc` model cannot even represent (`Doc.text` "must
  not contain `'\n'`"). `RFP-IMPL` should assert the non-overlap rather than inherit it by luck.

## 7. Cache identity

**Style policy must not enter semantic cache identity, and today it cannot.**

`CacheIdentity` is `source, toolchain, environment, formatter, configuration, validationLevel,
semanticSchema` (`Cache.lean:29`), and the payload it keys is `SemanticResult` — findings
(`Semantic.lean:7-12`). Findings are produced by rules over source bytes. Style policy cannot change
a finding, so it must not key the findings cache. It does not: `Config.lean` has no style keys, so
`configuration` carries none. The property holds by construction, and §3 keeping the surface empty is
what keeps it holding.

`formatter` is the application binary digest, so any change to `Printer.lean` already invalidates
every entry. Over-broad — a printer change invalidates findings that could not have moved — but
sound, and cheaper than a second digest.

**The constraint on `RFP-IMPL`.** If it caches canonical text, that payload *is* style-dependent, and
the rule inverts: whatever policy can change it must key it. The clean shape is a separate identity
for a separate payload — the semantic identity stays clean, and a format payload gets its own
component, which is empty today for exactly the reasons in §3. What must not happen is canonical text
cached under an identity that does not cover the policy that produced it; that is a stale-output bug
that no test will catch, because the cache will be *consistent* and *wrong*.

And note the shape of the trap: today's identity is accidentally correct. The moment a `group`
appears, `line-width` becomes observable and the existing entries become stale under an identity that
never mentioned it. That is why §3 requires the key and its identity component in the same commit.

## 8. Compatibility consequences and migration

**`format` gains behavior, and that is a breaking change for CI.** A file that is lint-clean but not
canonical is `format`-clean today, exit 0, and will be `would-format`, exit 1, after `RFP-IMPL`.
`tests/check/Layout.lean` is exactly that file. Any pipeline running `lean-fmt format` as a gate will
start failing on code that did not change.

This is a widening of a command's meaning, not a rename, so **there is no alias to add** — no old
name is being retired, and inventing `format-legacy` would preserve a behavior nobody chose (the
current semantics are an accident of the printer never being wired in, not a designed contract).

The migration is a command that already exists: **`check`**. It reports selected rules and, by §4,
does not move. Anyone whose `format` gate meant "does anything need fixing" wants `check`, which is
also *stricter* — it exits 1 on findings that have no fix, where `format` exits 1 only on
`changed > 0`. The two are not identical, and the difference favors the migration.

`RFP-FINAL` publishes this as the migration note. It is the whole of it.

## 9. The interface, designed twice

The new abstraction is the style surface. Per the prompt's Plan step 2:

**Design A — a `[format]` config section.** `line-width`, `indent-style`, `indent-width`,
`line-ending`. The Ruff-shaped answer, and the one a reader expects.

**Design B — no style surface.** The canonical layout is fixed. The margin is an internal constant.
Line endings are preserved because the lossless layer preserves them.

| | A | B |
| --- | --- | --- |
| caller knowledge | 4 keys, their types, their interactions | none |
| invariants hidden | none — it *exposes* the layout engine's margin, which the prompt's second stop rule forbids | the margin, the `Doc` model, the whole engine |
| error surface | invalid width, unknown indent style, conflicting line-ending policy — all new failure modes | none |
| exactness | unchanged | unchanged |
| cache identity | must grow 4 components, 3 of which key nothing | unchanged, and provably so (§7) |
| critical path | parse and validate 4 keys per run | nothing |
| memory enforceability | unchanged | unchanged |

**B wins, and not on taste.** Three of A's four keys cannot change a byte (§3), so A ships three
controls that lie to the user — and `line-width` specifically is the layout engine's own mechanism,
which the prompt's stop rule names. A's only honest key is `line-ending`, whose value would be
`preserve` for every caller, because that is what the lossless layer guarantees and no one has asked
to override it.

The cost of B is that it must be *revisited*, and the mechanism for that is §3's triggers: the first
`group` brings `line-width`, the first `nest` brings `indent-*`, each with its cache-identity
component in the same commit. A config surface is a permanent compatibility promise, and this stack
has nothing true to promise yet.

## 10. Remaining uncertainty

- **Whether `RFP-IMPL` can keep the cache.** §1's fact 3 is a real architectural obstacle: a cache
  hit carries no tree. Caching canonical text alongside findings is the shape I expect, but the
  identity discipline in §7 is the part that must not be improvised, and I have not built it.
- **Resolved, and the opposite of what I assumed:** FMT001/FMT002 are *not* subsumed by canonical
  text (§6, `evidence/02-canonical-text-still-lints.txt`). What remains open is the cost of the
  consequence — re-deriving findings against canonical text means a `fix` that formats cannot reuse
  the cached findings it already holds, and I have not measured what that does to the `fix` path.
  It may be that `fix` simply cannot take a cache hit; that would be sound, and slow.
- **What `format` should print for a file that is only *partly* claimable.** A `declaration` shell is
  canonical while its value is `verbatim`, so `format` will report `would-format` on files where most
  bytes are untouched. That is correct but may read as noisy; `RFP-FINAL` sees it on the frozen sample
  first.
