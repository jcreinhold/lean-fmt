# Applicability and conflict semantics

This freezes the model `RFX-IMPL` implements and `RFX-FINAL` attacks. It is a design note: no product
code changes under `RFX-SPEC` (see `results/01-model.md`). The current boundary — one boolean
`fixable`, every fix applied unconditionally, conflicts identified by array index — is characterized
in `evidence/01-no-applicability.txt`.

The vocabulary is ruff's, deliberately. ruff is the product this stack is named after and its fix
model is the source this note is faithful to: `Applicability::{Safe, Unsafe, DisplayOnly}`, a default
that applies safe fixes only, `--unsafe-fixes` to opt in, and `extend-safe-fixes` /
`extend-unsafe-fixes` to reclassify per rule. Where this note diverges from ruff it says so and why.

## 1. Applicability definitions

A **fix** is a proposed transformation attached to a finding. Its **applicability** is a claim about
what applying it preserves, and it is three-valued:

- **safe** — the rule's stated evidence guarantees the intended runtime/proof meaning is preserved.
  Applied by default.
- **unsafe** — the fix is plausibly what the user wants, but the rule cannot prove it preserves
  behavior, comments, or intent. Shown by default; applied only under explicit opt-in.
- **display-only** — the fix illustrates the finding and is never applied. It exists for a human or an
  editor to read, not for the transaction to execute.

"Safe" is not "reparses". The load-bearing phrase in the roadmap contract is *under the rule's stated
evidence*, and it ties applicability to the rule's tier (`LeanFmt/Rules.lean`, `Tier`):

- A **source**-tier rule sees normalized bytes and nothing else. It may claim **safe** only when the
  edit is meaning-preserving *at the byte level*, independently of how the bytes parse. Removing
  trailing horizontal whitespace (FMT001) and appending a final newline (FMT002) are the two examples
  the product already ships: neither can change how any Lean text elaborates, because Lean's lexer
  cannot see them. A source-tier rule that rewrote an identifier by text match could not claim safe —
  it has no evidence the match was an identifier and not a substring of a comment or string.
- A **syntax**-tier rule sees the exact frontend's projection. It may claim **safe** for an edit whose
  meaning-preservation follows from the parse (e.g. deleting a syntactically redundant token), and
  must claim **unsafe** when the parse is consistent with more than one intent (e.g. anything touching
  a comment, whose content the parse does not model).
- Semantic safety — "this rewrite is equivalent because it elaborates to the same term" — is a claim
  no current tier can make, because there is no semantic tier (`ruff-11`). A rule may not label a fix
  safe on semantic grounds until the evidence for that grounds exists. This is the same discipline
  that killed `RuleInfo.input`: a claim no code has to honor rots.

The definition therefore has a **validation obligation** attached, which is the roadmap's fourth
contract bullet: every applied fix passes exact-syntax validation (the candidate parses under the
exact module setup), and a fix that claims semantic safety may additionally require elaboration
validation. The product already has this ladder — `ValidationLevel.{syntax, elaboration}` and the
`--check-elab` flag (`LeanFmt/Cli.lean:81`). Applicability does not add a validator; it decides which
rung a given fix is obliged to clear. Today every shipped fix is safe by the byte-level argument above
and clears syntax validation, which is why `--check-elab` is already optional.

### Where applicability lives — designed twice

The choice is which type carries the value. It is the one new abstraction this note introduces, so it
is designed against the criteria the prompt names: caller knowledge, invariants hidden, error surface,
exactness, cache identity.

**A — a field on `Edit`.** `Edit` (`LeanFmt/ArtifactModel.lean:9`) is a byte range and a replacement.
Rejected. An `Edit` is a *fact about bytes*; applicability is a *judgment about intent*. They live in
the same file today only because both are report-shapes, but an `Edit` is also what an inverse patch
and the assembler manipulate (`LeanFmt/Edit.lean`), and none of that machinery has any business
carrying a safety claim. Worse, a single fix will grow to several edits (§4), and applicability is a
property of the fix as a whole, not of each byte range in it — putting it on `Edit` invites edits of
one fix disagreeing about their own safety, which is a state that should be unrepresentable.

**B — a field on `Finding`.** Rejected, but more narrowly. A `Finding` may have no fix
(`fix? : Option Edit`), and applicability of a nonexistent fix is meaningless; a field on `Finding`
would be an `Option`-shaped value that must stay `none` exactly when `fix?` is `none`, a coupled
invariant with no enforcement.

**C — a `Fix` structure that owns applicability and its edits, and `fix? : Option Fix`.** Chosen.
This is ruff's shape (`Fix { applicability, edits, .. }`) and it makes the coupling a matter of type:
a fix exists iff there is something to apply, and it carries exactly one applicability for its whole
edit set. `Finding.fix?` changes from `Option Edit` to `Option Fix`; `Fix` carries `applicability :
Applicability` and `edits : Array Edit` (one today, several later). Cache identity is unaffected —
findings are not in the artifact (`RRE-IMPL`), so no serialized identity mentions this. The migration
cost is real and named in §7.

The base applicability of a fix is the rule's own claim, set where the fix is constructed in
`LeanFmt/Rules.lean`, next to the edit it justifies. It is not a `RuleInfo` field: like the tier, it
is a property of a particular fix, and the two shipped rules both produce safe fixes.

## 2. Per-rule overrides

Applicability is a rule's claim; a project may **reclassify** it, and only through explicit
configuration — never inferred. Two config keys, matching ruff:

- `extend-safe-fixes = [selectors]` — promote the named rules' fixes to safe (apply an otherwise
  unsafe fix by default).
- `extend-unsafe-fixes = [selectors]` — demote the named rules' fixes to unsafe (withhold an
  otherwise safe fix from the default).

Selectors are the existing selector vocabulary (`all`, a category, a rule code), validated by the
existing `selectorsValid`. Precedence, frozen:

1. **Display-only is a floor.** Neither key can promote a display-only fix. A fix the rule refused to
   make applicable stays non-applicable; configuration cannot manufacture evidence the rule declined
   to assert. This is ruff's rule and the roadmap's ("display-only is never applied").
2. A rule named by **both** keys is a configuration error, rejected at load with the rule code — a
   contradiction, not a last-writer-wins.
3. Otherwise the effective applicability is: base, then promotion, then demotion, applied to the
   safe/unsafe axis only.

**Overrides are resolved as a projection, never read by a rule.** This is the same discipline as
selection: `RulePlan.findings` already projects rule enablement over canonical facts
(`LeanFmt/Config.lean:192`), and effective applicability is resolved in the same place, by the same
plan, from the config. A rule reading its own reclassification would reintroduce exactly the
two-deciders defect `RRE-SPEC` measured. So `RulePlan` gains the reclassification lists and a function
that maps a finding's fix to its effective applicability; `LeanFmt/Rules.lean` stays free of config.

## 3. Formatter interaction

The formatter (canonical layout) is **not a fix and has no applicability.** It is a canonical
transformation of the whole file, the product's definition of correct layout, applied by `format`,
`diff`, and `fix` alike (`prepareFile`, `LeanFmt/Application.lean:606`). Applicability governs *rule
fixes*, which compose *on top of* canonical text. Concretely: `fix` renders canonical text, then
applies the admitted rule fixes to it, using the canonical-coordinate findings
(`result.canonical?`, `LeanFmt/Application.lean:613`) — the coordinate discipline `RFP-SPEC` §6 froze.
Withholding an unsafe fix is simply excluding it from that edit set; the canonical result and every
safe fix are unaffected. A file that needs only layout still formats when all its fixes are withheld.

This resolves the decision `RRE-FINAL` deferred to this stack in `renderCanonicalText`'s docstring
("whoever adds the first syntax-tier rule with a fix decides what `format` does with it, and
`ruff-06`'s `RFX-SPEC` owns that decision"). The frozen answer, in two parts:

- **Composition model.** Rule fixes apply to canonical text in canonical coordinates. A source-tier
  fix is re-derived against canonical text already (`runSourceRules text`,
  `LeanFmt/Application.lean:337`); this is well-defined because the fix is a fresh finding over the
  rendered bytes. A **syntax-tier** fix cannot be re-derived this way without a second frontend run on
  the canonical text, because its evidence is the *original* projection. Frozen decision: a syntax-tier
  fix composes with layout by **re-projecting the canonical text** (parse the rendered file, run the
  rule against that projection), not by translating original-coordinate edits onto moved bytes. The
  alternative — applying non-source fixes to the original in a separate pass and formatting the result —
  is rejected: it makes the applied artifact depend on pass order (fix-then-format vs format-then-fix
  can disagree), which is the non-determinism the roadmap's "deterministic atomic fix-all" forbids.
  Re-projection is a measured cost (a second parse per file with a selected syntax fix) and `RFX-IMPL`
  pays it only when such a rule is selected, exactly as `requiredTier` already gates projection.
- **Applicability of the layout itself.** Layout is definitionally safe and unconditional; there is no
  `--unsafe-fixes` gate on formatting. This keeps `format`/`diff` (which never apply rule *fixes* to
  disk) orthogonal to the applicability machinery: they render layout and *report* fixes with their
  applicability, and only `fix` acts on the safe/unsafe distinction.

No shipped rule is syntax-tier, so the re-projection path is specified now and exercised by `RFX-FINAL`
through the engine's rule-array seam (`runRulesOf`), not by shipping a fake rule.

## 4. Conflict provenance

Two fixes **conflict** when their edits cannot both apply to one snapshot: overlapping ranges, or two
insertions at the same point (the existing `conflict?` predicate, `LeanFmt/Edit.lean:73`, is correct
and unchanged). Conflict resolution **never guesses** — no fix wins, no edit is dropped — the whole
transaction for that file is rejected. What changes is the *provenance* carried out of the rejection.

Today `PatchError.conflict` reports `leftIndex rightIndex : Nat`, positions in the sorted edit array
(`evidence/01` §4). That is unactionable: a user cannot map an internal array index to a rule. Frozen:
a conflict rejection names, for each side, the **rule code** and the **source range** of the finding
whose fix is involved. This requires the finding→edit link to survive into conflict detection, which
`filterMap (·.fix?)` currently discards (`LeanFmt/Edit.lean:113`). `RFX-IMPL` threads provenance
(rule code + finding range) alongside each edit through sorting and conflict detection, so the error
can cite both rules. The error's rendered form (`ToString PatchError`, `LeanFmt/Edit.lean:16`) becomes
"edits from RULE_A (a-b) and RULE_B (c-d) conflict" rather than "edits 3 and 5 conflict".

A fix's own edits (several, one finding) are not in conflict with each other by construction — a
well-formed multi-edit fix has disjoint ranges, checked when the fix is built, so the transaction-level
conflict check is strictly between fixes of *different* findings.

## 5. File and project atomicity

Two scopes, and only one is a real transaction.

- **File atomicity (the transaction unit).** A file's admitted fixes apply as one all-or-nothing patch
  or the file is left byte-identical and reported. This is already true structurally — `preparePatch`
  rejects the whole edit set on the first bad or conflicting edit, and `publishAtomic` writes a temp
  file and renames, so a crash leaves either the old file or the new file, never a half-written one
  (`evidence/01` §5). `RFX-FINAL` attacks exactly the crash-between-validation-and-rename window; the
  temp-then-rename structure is what makes that window survivable and must be preserved.
- **Project result (a deterministic aggregate).** Fix-all over many files is the deterministic
  sequence of per-file transactions. Its atomicity guarantee is *no file is left partial* — each file
  is independently all-or-nothing — **not** that all files roll back together.

Frozen decision: **no cross-file two-phase commit.** A project-wide all-or-nothing (stage every file's
temp, rename all at the end, roll back all on any failure) is rejected, for reasons the note records so
`RFX-IMPL`/`RFX-FINAL` do not relitigate it:

1. Files are independent inputs; one file's rejected fix is not evidence against another file's
   accepted one. A formatter that refused to fix 8,000 clean files because the 8,001st had a conflict
   would be worse, not safer.
2. It multiplies the crash window rather than shrinking it: a batch rename is still not atomic across
   files on any filesystem this product targets, so "all or none" would be a claim the OS cannot honor —
   precisely the kind of unbacked guarantee this codebase refuses elsewhere ("Filesystem presence is
   not build validity", AGENTS.md).
3. It fights the existing per-snapshot loop (`execute`, `LeanFmt/Application.lean:780`) and the stop
   rule against reintroducing per-file orchestration complexity.

The roadmap contract's "reject the atomic file *or* project transaction with provenance" is honored by
reading the "or" as *scope selection*, not a demand for both: a conflict rejects the **file** it occurs
in, with provenance, and the project report records that file as rejected while the rest proceed
deterministically. "Deterministic atomic fix-all" is then: deterministic file order, each file atomic,
partial-project outcomes reported exactly (which files fixed, which rejected and why).

## 6. CLI: showing versus applying

The split is: **`check`, `format`, `diff` show; `fix` applies.** Applicability sharpens both sides.

- **Showing (all modes, JSON and text).** Every reported finding that carries a fix reports the fix's
  effective applicability. JSON gains the value on the fix; text output names it (e.g. a `[safe]` /
  `[unsafe]` / `[display-only]` marker on the finding line, and `rules` output replaces the bare
  `fixable` column with the fix's applicability). This is contract bullet 2 ("Applicability is present
  in JSON and text explanations"). `format`/`diff` continue never to write source; they preview
  canonical layout and *report* which additional fixes exist and whether they are safe.
- **Applying (`fix`).** Default applies **safe** fixes only. Unsafe fixes are reported as available and
  withheld; display-only is never applied. A new flag **`--unsafe-fixes`** (ruff's spelling) opts into
  applying unsafe fixes too — still subject to validation and conflict rejection. There is no flag that
  applies display-only fixes, by construction.
- **Report shape.** `fix` must distinguish, per file, fixes *applied* from fixes *available but
  withheld* (unsafe, without `--unsafe-fixes`), so a user sees what `--unsafe-fixes` would add. The
  frozen surface: `FileReport` gains counts (or a status) separating applied from withheld-unsafe;
  `RunReport` aggregates a withheld-unsafe total. Exit codes are unchanged in spirit — `fix` exits 0
  when it leaves the tree in its intended state; withheld unsafe fixes do not by themselves make `fix`
  fail, because the default intended state excludes them.

`--unsafe-fixes` is CLI-only in this stack. A config equivalent is deferred: ruff has none as a global
bool (it uses the per-rule extend lists, which this note already adopts in §2), and inventing one here
would add a fourth way to say the same thing the extend lists say per rule.

## 7. Migration cost and remaining uncertainty

**`fix? : Option Edit` → `Option Fix` touches every fix site and every reader.** Producers:
`LeanFmt/Rules.lean` (two rules). Readers: `preparePatch` (`filterMap (·.fix?)` becomes a flatten over
`fix.edits` with applicability carried for provenance and admission), `Finding`'s `ToJson`/`FromJson`
derivation, and any test constructing a `Finding` literal (`LeanFmtTest.lean`). This is a breaking
model change with no serialized-identity fallout (findings are not in the artifact), so there is no
schema bump — unlike `artifactSchema`, a `Finding` never round-trips through an `.olean`.

Uncertainties carried to `RFX-IMPL`:

- **The exact text markers** for applicability in `check`/`rules` output are a presentation choice the
  note does not over-specify; `RFX-IMPL` picks spellings and pins them in `tests/modes`/`tests/check`.
- **Whether `--unsafe-fixes` interacts with `--select`.** Provisional: orthogonal — `--select` chooses
  *which rules* run, `--unsafe-fixes` chooses *which admitted fixes* apply. A selected rule whose fix
  is unsafe is reported by `check` and withheld by `fix` unless `--unsafe-fixes`. `RFX-IMPL` confirms.
- **Multi-edit fixes** (`edits : Array Edit`) are specified but unexercised until a rule needs one; the
  first such rule (plausibly an import rule, `ruff-09`) is where disjoint-edit validation inside a fix
  earns its first test. The model reserves the shape; `RFX-IMPL` need not build the producer.
