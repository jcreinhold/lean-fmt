# RSP-SPEC — Specify suppression grammar and scope

**Verified.** The design is `notes/01-spec.md`. This records what was run, what it showed, and what
changed while writing it.

No product behavior changed. One evidence file and two notes (design + this result). `LeanFmt/` is
untouched, which is the correct footprint for a spec prompt and is what `state/next.md` declared this
prompt to be ("Module: (docs only)"). The prior spec prompts in this family, `RRE-SPEC` and
`RFX-SPEC`, have the same footprint.

## The headline

**There is no source-suppression layer.** A `lean-fmt:` comment is ordinary comment trivia and has
zero effect on findings: a tree-wide scan for the concept (`suppress`, `ignore[`, `noqa`, `lean-fmt:`,
`disable-next`, `directive`) returns nothing, and a well-formed directive placed next to a genuine
finding — leading, file-level, or inline — leaves the finding reported exactly as if the comment were
prose (`evidence/01-no-suppression.txt`).

The model the note freezes:

- One native grammar, `-- lean-fmt: ignore[CODE]`, adapted from ruff's `noqa` but spelled in Lean's
  comment syntax (ruff's is Python's `#`). Three verbs = the roadmap's three forms: `ignore`
  (same line), `ignore-next` (next item), `ignore-file` (whole file). Blanket = a verb with no
  `[selectors]`.
- Directives are read only from `Comment` trivia via `Comments.attach`, never by substring search.
  Strings, syntax quotations, and doc comments (`/--`, `/-!`) are therefore excluded **by
  construction** — none are trivia — which satisfies two stop rules and `RSP-FINAL`'s doc-comment case
  for free.
- Scope is a byte range in the normalized source, derived from the comment's position every run and
  never stored; that is what makes it deterministic under formatting.
- Malformed (`FMT901`) and unknown-code are different policies; unused (`FMT900`) is the first-party
  rule with the safe removal fix. Infrastructure failures are unsuppressible because suppression is a
  filter on `Array Finding` and they never enter that array.
- Suppression is a projection over canonical findings, alongside `RulePlan`, and — like selection —
  must not enter the result cache key.

## Commands run

```sh
LEAN_NUM_THREADS=1 lake build                                    # baseline, exit 0 (36 jobs)
grep -rinE "suppress|ignore\[|noqa|lean-fmt:|disable-next|directive|unused.suppress" \
    LeanFmt/ Main.lean LeanFmtTest.lean docs/adding-a-rule.md \
    | grep -viE "IO.eprintln|block are suppressed"              # no matches
app=$(lake -q query lean-fmt --text)
"$app" check <fixture>                                           # 3 directive fixtures, all inert
tests/boundary/run.sh                                            # exit 0
git diff --check                                                 # no output
check_stack.py    docs/projects/ruff-07-suppressions --structural   # OK: 3 prompt(s), 0 warnings
write_next.py --check docs/projects/ruff-07-suppressions         # matches first_unresolved
```

Environment: commit `93768f3`, `leanprover/lean4:v4.32.0`, Darwin 25.5.0 arm64. No performance claim
is made here — the measurements are a source scan and three `check` invocations of single small files,
none timing-sensitive — so no RSS/pressure/swap record applies. The prerequisite stacks
`ruff-05-rule-engine`, `ruff-05b-semantic-facts`, and `ruff-06-fix-safety` are all `verified`; their
live code was re-read here (`Rules.lean`, `Config.lean`, `Comments.lean`, `LosslessSource.lean`,
`Application.lean`) rather than trusted, and every claim in the note cites a file and line.

## What was measured

**1. No suppression vocabulary exists (`evidence/01` §1).** The tree-wide concept scan over `LeanFmt/`,
`Main.lean`, `LeanFmtTest.lean`, and `docs/adding-a-rule.md` returns no match. The two pre-existing
hits it excludes are unrelated (`IO.eprintln` error prints; a Printer comment about `by`-block byte
shifts).

**2. A well-formed directive is inert (`evidence/01` §2).** Three fixtures, each pairing a genuine
finding with a directive:
- leading `-- lean-fmt: ignore[FMT001]` above a trailing-whitespace line → `FMT001` still reported;
- `-- lean-fmt: ignore-file` near the top of a file with a trailing-whitespace line → `FMT001` still
  reported;
- inline `-- lean-fmt: ignore[FMT002]` on the last line of a file with no final newline → `FMT002`
  still reported.

The initial inline fixture put the whitespace *before* the trailing comment, which is not trailing
whitespace at all (the comment ends the line), so FMT001 correctly did not fire — a useful reminder,
now in the note (§3): inline same-line suppression is meaningful for code-level rules (`ruff-08`+),
while the whitespace/newline rules the product ships today exercise leading/file/inline-on-EOF
placements. The three fixtures above are the corrected, genuine finding+directive pairs.

**3. The raw material already exists (`evidence/01` §3).** Those directive comments are `lineComment`
trivia the lossless model already records; `Comments.attach` partitions each as
`Comment{kind := .lineComment, range}`. Only interpretation — parse the directive text, project over
findings — is missing, which is `RSP-IMPL`.

## Decisions changed during execution

- **Explicit verbs over attachment-inferred scope.** The first sketch inferred same-line vs next-item
  from whether the comment trails or leads code. Rejected in the note (§2): moving a comment between
  positions would silently change scope. Three explicit verbs instead, each matching a convention users
  already know.
- **Anchor on `finding.range.start`, not full containment** (§3). Forced by FMT002's empty `[eof, eof)`
  range and FMT001's range ending at the newline — full containment would treat both as boundary edge
  cases.
- **Unknown code is not malformed** (§5). Split out as a separate, maintainable state (rule renamed or
  removed) surfaced through the unused rule, matching ruff's RUF100, rather than folded into the
  malformed-syntax policy.

## Remaining uncertainty (handed to RSP-IMPL)

- **Tier of unused-detection on a source-only run** (`notes/01-spec.md` §11). The unused rule needs the
  projection (syntax-tier), but a `check` whose selected rules are all source-tier does not otherwise
  obtain it. Recommended: run unused-detection only when the projection is already demanded, keeping a
  pure source run source-tier; document the corner. `RSP-IMPL` decides.
- **Reserved codes `FMT900` (unused) / `FMT901` (malformed).** Proposed here in a `9xx`
  self-diagnostic band distinct from the `00x` rule band; `RSP-IMPL` confirms against the registry and
  finalizes the malformed fix applicability (display-only or unsafe — never safe auto-removal).
- **`ignore-next` scope for multi-line items.** Defined as `[command.start, command.stop)`; `RSP-IMPL`
  confirms the command span is reachable from the `Attachment`/projection without a second frontend
  pass.
