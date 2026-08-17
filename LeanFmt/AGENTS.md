# Writing Lean in LeanFmt

Rules for the library modules. The root `AGENTS.md` owns the product constraints, and nothing here contradicts it.

## Proofs

`LeanFmt/Cache/Spec.lean` proves the currency decision sound and complete. `lake build` builds it, so a broken proof
fails the build. The axiom audit does not run in the build.

After you change `Cache/Spec.lean` or `Cache/Decision.lean`, run `#print axioms` over the theorems and review the
output; a new assumption will not announce itself. Do not mark a claim verified on the old record.

Do not commit `sorry`, `admit`, or a new `axiom`.

Quantify over the operation you prove about; do not define it. A proof about "whatever the cache returns" says nothing.
Carry an assumption as a hypothesis, not an axiom. Show the hypotheses can hold together, as `serves_hits_somewhere`
does, or the theorem is empty.

## Comments

Comment what the code does not state: why a step exists, which constraint it serves, an invariant, a convention. Do not
restate the code or repeat the declaration's name. A docstring tells a caller what a declaration means and how to use
it.

## Names

Name a public declaration for what it is in the product, not for its place in a proof or a call chain. Do not use
`helper`, `tmp`, `plumbing`, or a public `aux`. If several declarations repeat one construction, name the construction.

## Options and unsafe

Do not commit a `set_option` in a production module. FMT010 reports them in the code we format, and the rule holds here
too.

`unsafe` originates in `LeanFmt/Analysis.lean`, where the frontend requires it, and it is contagious to callers. The
`IncrementalAnalyzer` surface is sealed back to safe code by four `@[implemented_by]`/`opaque` pairs, so the LSP path
carries none of it; `analyzeExact` is not sealed, so the `unsafe def`s in `Application.lean`, `Cli.lean`, and
`Main.lean` are that one propagation and nothing else. A new `unsafe` that is not propagation from `Analysis.lean` needs
a reason in the commit message — and grep for the modifier, not the word: `unsafe` also names an `Applicability`
constructor and the `--unsafe-fixes` flag.
