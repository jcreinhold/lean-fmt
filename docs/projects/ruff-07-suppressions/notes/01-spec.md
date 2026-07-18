# Source suppression grammar and scope

This freezes the model `RSP-IMPL` implements and `RSP-FINAL` attacks. It is a design note: no product
code changes under `RSP-SPEC` (see `results/01-spec.md`). The current boundary — no directive is
honored; a `lean-fmt:` comment is ordinary comment trivia with zero effect on findings — is
characterized in `evidence/01-no-suppression.txt`. The prior spec prompts in this family, `RRE-SPEC`
and `RFX-SPEC`, have the same docs-only footprint.

The vocabulary is adapted from ruff, the product this family is named after, but the *syntax* is
Lean's, because ruff's is Python's. Ruff spells suppression on a `#` line comment (`# noqa: E501`,
`# ruff: noqa`); Lean has no `#` comment. The stop rule "avoid Python `noqa` syntax if it conflicts
with Lean comment conventions" forces a native spelling, and the roadmap already proposes one:
`-- lean-fmt: ignore[CODE]`. This note adopts that and pins the rest.

## 1. Where a directive may live — the comment-trivia constraint

A directive is read **only** from a `Comment` (`LeanFmt/Comments.lean:30`), i.e. from a `lineComment`
or `blockComment` trivia enumerated by `Comments.attach`. It is never found by substring search over
the source. The comment's own byte range slices the normalized source; the directive grammar (§2) is
parsed from that slice and nothing else.

Three consequences fall out for free — structural, not enforced by a guard:

- **Strings and quotations are excluded.** A string literal or a syntax quotation is a `Syntax` leaf,
  not trivia, so `"lean-fmt: ignore[FMT001]"` inside a string is invisible to `Comments.attach`. This
  is the stop rule "a directive inside a string or quotation is not a comment directive", satisfied by
  construction rather than by a special case.
- **Doc comments are excluded.** `/-- … -/` and `/-! … -/` are *not* trivia: `TriviaKind` has
  `whitespace | lineComment | blockComment` only, because "doc-comment and module-doc openers are real
  tokens, so they arrive as syntax nodes" (`LeanFmt/LosslessSource.lean:36-38`). A `lean-fmt:` line
  inside a docstring is therefore not a directive. This answers `RSP-FINAL`'s doc-comment case in
  advance: docstrings never suppress.
- **A broken file cannot suppress its own breakage.** A file that fails to parse has no
  `LosslessSource` projection and hence no `Attachment`, so no directive can be read from it. This is
  one half of §6.

## 2. The directive grammar

Lexical frame: strip the comment's opener (`--` or `/-`) and, for a block comment, its closer (`-/`),
then strip surrounding whitespace. The remaining content is a directive **iff** it begins exactly with
the sigil `lean-fmt:`. A comment whose content does not begin with the sigil is an ordinary comment and
draws no diagnostic (§5 distinguishes this from a malformed directive).

```
directive  ::= "lean-fmt:" ws? verb (ws? selectors)?
verb       ::= "ignore" | "ignore-next" | "ignore-file"
selectors  ::= "[" ws? code (ws? "," ws? code)* ws? "]"
code       ::= upper (upper | digit)*          -- the registered rule-code shape, e.g. FMT001
ws         ::= (" " | "\t")+
```

- A **blanket** directive is a verb with no `selectors`.
- At most one directive per comment; the directive is the comment's entire content. A block comment
  holds at most one directive.
- The three verbs are the roadmap's three forms (inline / next-item / file), named explicitly rather
  than inferred from whether the comment leads or trails code. Inference was considered and rejected:
  it makes moving a comment from trailing to leading silently change scope. Explicit verbs match the
  established conventions users already know — `ignore` ≈ ruff `# noqa` (this line), `ignore-next` ≈
  `// eslint-disable-next-line`, `ignore-file` ≈ ruff `# ruff: noqa` (whole file).

## 3. The three scopes — byte/range based, deterministic under formatting

A scope is a byte range in the **normalized** source (the one coordinate system every finding and
projection shares; `LeanFmt/Rules.lean:57-62`). It is **derived from the directive comment's position
every run, never stored** — that is precisely what makes it "deterministic under formatting". The
directive and its target move together when the file reflows, so the suppression relationship is
preserved without any absolute offset that a reflow could invalidate.

A finding is in scope iff its **anchor** — `finding.range.start` — lies in the scope's half-open byte
range. Anchoring on the start (not full containment) keeps line rules robust at boundaries: FMT001's
range ends *at* the newline and FMT002's is the empty `[eof, eof)` range, both of which full
containment would treat as edge cases.

- **`ignore` — same line.** Scope = the physical source line the directive comment sits on,
  `[lineStart, lineStop)` (from the newline before the comment's start, exclusive, to the next
  newline, exclusive). A **trailing** directive suppresses the code line it trails — the intended
  inline use. A bare `ignore` alone on its own line covers only that comment line, which normally
  carries no finding, so it suppresses nothing and is reported unused (§7). This matches ruff `# noqa`
  being strictly line-based.
- **`ignore-next` — next item.** Scope = the span of the command/item the directive comment leads:
  `[command.start, command.stop)` for the next top-level command in source order — the token whose
  `leading` run owns this comment (`Comments.attach`). For today's line-oriented rules this is the
  next declaration's line(s). This is the "next-item" form the roadmap names.
- **`ignore-file` — whole file.** Scope = `[0, terminalStop)`, the entire module the projection
  models. The verbatim tail after a terminal command (`eoi`/`#exit`, `LeanFmt/LosslessSource.lean`
  `terminalStop`) is out of scope by construction, because no rule reports into it. Placement is
  independent (any comment with this verb scopes the file), but a header or standalone comment is the
  recommended and documented placement. Matches ruff `# ruff: noqa`.

## 4. Selectors — specific, list, blanket

- `ignore[FMT001]` — one code. `ignore[FMT001, FMT002]` — a list (comma-separated, whitespace
  optional). Both suppress only the named codes whose findings are in scope.
- Blanket `ignore` (no brackets) — suppresses every code whose finding is in scope.
- **Blanket policy.** Permitted but discouraged: a blanket hides findings from rules that do not yet
  exist, which is exactly the drift this family fights. It is therefore subject to unused-detection
  like any coded directive — a blanket that suppresses nothing in scope is unused (§7) — and it can
  never reach an infrastructure failure (§6). A future config key may forbid blankets entirely; that
  is out of scope here and noted for `ruff-13`.
- Duplicate codes in one list, or two overlapping directives naming the same code, are idempotent; the
  redundant one is flagged unused-per-code (§7).

## 5. Malformed vs unknown — two different policies

- **Malformed** — the content opens with `lean-fmt:` but breaks the grammar: an unclosed `[`, an empty
  `[]`, junk after the directive, an unterminated selector, or a `code` that does not match the
  code shape. Policy: emit a first-party **finding** (§ reserved code `FMT901`, "malformed suppression
  directive") located at the comment, and **suppress nothing**. A malformed directive must never
  silently suppress and never silently vanish — a typo the author believes is active would otherwise
  disable protection invisibly. The malformed finding carries at most a display-only or unsafe fix
  (removing a broken directive may discard the author's intent), never a safe auto-removal.
- **Not a directive** — content that does not open with the sigil is an ordinary comment: no finding,
  no diagnostic. This is the line that keeps the malformed policy from firing on every prose comment.
- **Unknown code** — the grammar is valid but the `code` names no registered rule (e.g.
  `ignore[FMT999]`). Policy: **not malformed.** It suppresses nothing (no such rule) and is reported by
  the unused-suppression rule (§7) with an "unknown code" reason. This matches ruff, where an unknown
  code in a `noqa` is still well-formed and surfaces through RUF100. The distinction is deliberate:
  unknown-code is a maintainable state (a rule was renamed or removed) fixed by editing the code list;
  malformed is a syntax error fixed by rewriting the directive.

## 6. What can never be suppressed

- Suppression is a **filter on `Array Finding`**. Infrastructure outcomes — parse failure, rejected
  source, validation failure, IO error, the stale-source check — are `FileReport.diagnostics` and
  status, never findings (`LeanFmt/Application.lean` `baseReport`/`validationReport`), so they cannot
  enter the filter. Structural, not a guard. This is the roadmap contract "cannot suppress
  syntax/infrastructure failures" and the `RSP-IMPL` stop rule "infrastructure diagnostics remain
  unsuppressible."
- A file that does not parse has no comment model, so a directive cannot even be read (§1).
- The malformed-directive finding (§5) and the unused-suppression finding (§7) are themselves **not
  suppressible** by any directive: a directive cannot silence the report of its own misuse. They are
  excluded from the suppression filter's domain.

## 7. Unused suppressions — the first-party rule and safe fix

This is the roadmap's headline deliverable: "a first-party diagnostic and safe fix for unused
suppressions" (ruff's RUF100).

- A directive **code** is *unused* when no finding carrying that code has its anchor in the directive's
  scope, among the findings that survive **config selection** for the path (§8). A blanket directive is
  unused when it suppresses nothing in scope.
- The unused-suppression finding (§ reserved code `FMT900`, "unused suppression directive") reports
  each unused directive or unused code, with a **safe** fix:
  - a blanket or single-code directive that suppressed nothing → remove the whole comment and the
    whitespace it owns. This is the *only* case in the product where a comment is removed; the fix must
    round-trip every other comment exactly once (`Comments.partitions`; `RSP-FINAL` stop rule).
  - a list with some codes used and some not → rewrite the list, dropping only the unused codes.
- **Safety argument.** Editing or removing a comment is meaning-preserving at the byte level — the
  lexer cannot observe comment content — which is the source-tier safety argument FMT001 already uses
  (`notes` of `ruff-06`, §1). So the fix is genuinely *safe*, not merely plausible.
- **Layer and tier.** The rule reasons over (directives ∩ findings), which no single-rule fact view
  has, so it is **not** a `RuleImpl` and does **not** live in `ruleRegistry`. It is computed in the
  suppression projection, after `runRules`, exactly like selection. Because it needs the `Attachment`,
  which needs the lossless projection, it is conceptually **syntax-tier**; §11 records the one open
  question this raises for a source-only run.

## 8. Precedence — config layer vs source layer

Two independent filters over canonical findings, kept as different layers per the roadmap ("per-file
configuration ignores and source suppressions remain different layers with predictable precedence"):

1. **Config layer** (existing `RulePlan`, `LeanFmt/Config.lean`): `--select` / `--ignore` /
   `per-file-ignores` decide which rules are *active* for a path.
2. **Source layer** (new): directives suppress active-rule findings by scope (§3).

A finding is reported iff **(config-selected for the path) AND (not source-suppressed)**. This is an
intersection, so the order of the two layers does not change *what is reported*. It changes only
unused-detection: unused runs against the **config-selected** finding set, so a source
`ignore[FMT001]` on a path where FMT001 is config-disabled is *unused* — it can never fire. This is
ruff's behavior and is the predictable rule; it is documented here so the precedence is not
surprising.

The two layers stay distinct spellings for distinct intents and neither subsumes the other: a config
ignore is project policy ("this rule is off for `generated/**`"); a source suppression is a local,
diff-visible exception annotated at the site it applies to.

## 9. Formatting preservation

Directives are comments, and the formatter round-trips every non-removed comment exactly once
(`Comments.partitions`, `LeanFmt/Comments.lean:192`). Suppression *reads* comments; it never rewrites
them. The single comment-removal path is the unused-fix (§7), which removes exactly the flagged comment
and must re-establish the round-trip invariant on the remainder. "Deterministic under formatting" is
§3 restated: scope is derived from attachment/position at analysis time, and formatting preserves
attachment, so every suppression relationship survives a reflow.

## 10. The new abstraction, designed twice

The one new abstraction is the parsed directive plus the suppression projection. The prompt asks it be
designed against caller knowledge, invariants hidden, error surface, exactness, and cache identity.

- **A — directives threaded through the rule engine as finding-adjacent data.** *Rejected.* It would
  put comment interpretation inside `runRules`, whose contract (ruff-05) is facts→findings with no
  cross-finding view and no selection. Suppression is a projection over results, exactly like
  `RulePlan.findings`. Placing it in the engine repeats the `RuleInfo.input` mistake — a claim in the
  wrong layer that no code has to honor.
- **B — a `Suppression` projection alongside `RulePlan`.** *Chosen.* It consumes the comment
  `Attachment` and the canonical findings and produces `(kept findings, suppressed count, unused and
  malformed diagnostics)`.
  - *Caller knowledge*: the report path already holds both the projection (for canonical rendering)
    and the canonical findings; it gains one call.
  - *Invariants hidden*: scope computation, the malformed/unknown policy, unused detection, the
    unsuppressible-diagnostics rule.
  - *Error surface*: a malformed directive becomes a finding, never an exception.
  - *Exactness*: byte-range over the same normalized coordinate system every finding uses; no second
    coordinate system is introduced.
  - *Cache identity*: **suppression is a projection, so, like selection, it must not enter the result
    cache key.** One cached canonical-findings entry serves any suppression outcome; toggling a
    directive re-projects and never re-elaborates. This is the load-bearing constraint carried from
    ruff-05 and the `RSP-IMPL` stop rule "suppression state never changes required semantic capability
    or cache identity."

## 11. Cache identity, tier, and the one open question for RSP-IMPL

Directives never change `demandedTier` or cache identity (§10). But the unused-suppression rule is
syntax-tier: it needs the `Attachment`, which needs the lossless projection. Adding it does **not** put
it in `ruleRegistry`, so `RulePlan.requiredTier` — a fold over the registry — is unchanged. The open
question is operational: on a `check` run whose selected rules are all source-tier, the projection is
not otherwise obtained. Two options for `RSP-IMPL`:

- (a) run unused-detection only when the projection is already demanded, leaving a pure source run at
  source-tier and simply not reporting unused directives there; or
- (b) let the presence of any `lean-fmt:` directive demand syntax facts, so unused-detection always
  runs.

Recommended (a): a pure source run stays source-tier and cheap, and the corner ("unused directives are
reported only on runs that already parse") is documented rather than paid for on every run.
`RSP-IMPL` finalizes this and confirms the two reserved codes `FMT900`/`FMT901` against the registry
(the `9xx` band is reserved here for the formatter's self-diagnostics, distinct from the `00x` rule
band).
