# RSP-FINAL — Verify scopes, formatting stability, and recovery

**Verified.** The suppression layer was driven through the full acceptance matrix over the real
parser and the real CLI: nested syntax, same-line comments, doc comments, custom commands, formatting
movement, unknown rules, file ignores, per-file config, and unused fixes. Every case behaves as the
completion contract requires; nothing was weakened to make a case pass. The raw transcript is
`evidence/03-acceptance.txt`, and the whole matrix is now a committed regression suite,
`tests/suppression/run.sh`.

## What was tested and what held

- **Doc comments / module docstrings are inert.** `/-- … lean-fmt: ignore-file … -/` and `/-! … -/`
  are *tokens*, not comment trivia, so directive-looking text inside them parses as nothing: the
  `FMT001` on the fixture's trailing-whitespace line still reports, `suppressed=0`, and no `FMT900`/
  `FMT901` appears. This is the `RSP-SPEC` "a directive is a comment, nothing else" stop rule, now
  confirmed against the real parser rather than by construction alone (`tests/suppression/DocComment.lean`).
- **Nested syntax.** An `ignore-next` inside a `namespace` suppresses the inner finding
  (`suppressed=1`, `findings=0`) — scope resolution walks the command tree, not the top level
  (`Nested.lean`).
- **Custom commands.** A file-local `syntax`/`macro_rules` pair plus a `greet` command: `ignore-file`
  suppresses the finding on the custom command and the command round-trips unchanged. File-local
  syntax effects are preserved; the directive reads from trivia regardless of the command's grammar
  (`Custom.lean`).
- **Same-line comments.** A trailing `-- lean-fmt: ignore` on a line whose own trailing whitespace is
  `FMT001` suppresses it (line scope covers the finding on the comment's line). The unused-directive
  removal for a *trailing* directive eats back only the inter-token whitespace and keeps the code's
  newline — a different `removalRange` branch than a standalone directive (checked in the matrix and
  `Suppression.removalRange`).
- **Formatting movement + round-trip.** `ignore-next` spans a multi-line item; `fix` reflows the item
  and removes the trailing whitespace the directive was suppressing. Through the reflow the directive
  comment round-trips **exactly once** (the stop rule), a second `fix` writes nothing (idempotent),
  and the now-genuinely-unused directive is reported as `FMT900` on the next `check`. The directive
  tracked its target across reformatting; the finding was simply fixed away — the honest outcome, not
  a stale scope (`Movement.lean`). This closes the "formatting movement" uncertainty handed forward by
  `RSP-IMPL`.
- **Unknown rules.** `ignore[FMT999]` suppresses nothing: the real finding still reports **and** an
  `FMT900` unused-directive is raised. An unknown code is never silently honored.
- **File ignores.** `ignore-file` at the top of the file suppresses every finding (header scanner from
  `RSP-IMPL`); exercised again here through `Custom.lean` and the `DocComment.lean` fixture's target.
- **Per-file config composition.** With a config `per-file-ignores."**/PerFile.lean" = ["FMT001"]`, a
  directive naming `FMT001` suppresses nothing — the config already dropped it — so the directive is
  itself unused (`FMT900`), `suppressed=0`. Config selection and source suppression are different
  layers with predictable precedence: config projects first, suppression projects over what remains,
  and a directive redundant with config is the RUF100 analog. Confirmed identically with CLI
  `--ignore FMT001` (`PerFile.lean`, `lean-fmt.toml`).
- **Unused fixes — the final boundary.** A blanket `ignore` over a clean file is `FMT900` with a
  **safe** removal fix whose single edit deletes exactly the directive line *and* its terminating
  newline (`edit=8..28`, `replacement=""`), leaving `module\n\ndef …\n` with no blank line. Batch
  `fix` does **not** apply it — `fix` reformats and preserves comments, so the removal is an editor
  code-action, surfaced via `--json`/LSP with `applicability: safe`. `check` still exits non-zero on
  the `FMT900`; `fix` exits zero because it reformatted successfully. This is the intended
  lint-vs-format split, and it is the final answer to `RSP-IMPL`'s open "`fix` and unused directives"
  question: the boundary stays, because auto-removing directives during a format pass would let `fix`
  silently delete a comment the author wrote — exactly what the round-trip stop rule forbids. The
  `FMT901` malformed fix is `display-only` (an advisory marker, never applied).

## Commands run

```sh
LEAN_NUM_THREADS=1 lake build                          # exit 0
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests             # module-artifact tests passed (incl. testSuppression)
tests/suppression/run.sh                               # suppression acceptance tests passed  (new)
tests/boundary/run.sh                                  # native boundary passed
tests/check/run.sh tests/modes/run.sh tests/printer/run.sh \
  tests/layout/run.sh tests/semantic/run.sh tests/lossless/run.sh \
  tests/service/run.sh                                 # all exit 0
git diff --check                                       # clean
check_stack.py    docs/projects/ruff-07-suppressions --structural
write_next.py --check docs/projects/ruff-07-suppressions
```

Environment: `leanprover/lean4:v4.32.0`, Darwin 25.5.0 arm64. No full-mathlib run (the roadmap does
not authorize one for this stack). No performance claim; measurements are `check`/`fix` on small
single-file fixtures.

## What landed for regression

- **`tests/suppression/run.sh`** (new) with eight committed fixtures + a `lean-fmt.toml`, registered in
  `AGENTS.md`. It drives the acceptance matrix through the real CLI and asserts on `--json`. The
  fixtures carry deliberate trailing whitespace; `.gitattributes` exempts them from
  `git diff --check`. The `tests/` tree is outside the printer corpus glob
  (`git ls-files 'LeanFmt/*.lean' 'Main.lean'`), so these fixtures do not move any shape figure.
- **`LeanFmtTest.lean`** `testSuppression` gained one assertion: the `FMT900` removal edit deletes
  exactly the directive line and its newline (range `⟨7, 32⟩`, empty replacement), freezing the
  clean-line-removal shape at the unit layer.

## Remaining uncertainty

- None that blocks the claim. The suppression layer meets every completion-contract item: one
  documented comment grammar parsed from lossless trivia (never substring), deterministic byte-range
  scopes that cannot touch syntax/infrastructure failures, explicit policy for unknown/malformed/
  blanket/unused directives, and config-ignore vs. source-suppression kept as distinct layers with
  predictable precedence. The only deliberate boundary is that batch `fix` does not remove unused
  directives — decided above as the final, correct behavior.
