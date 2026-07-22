# Writing Lean in LeanFmt

Rules for the library modules. The root `CLAUDE.md` owns the product constraints, and nothing here
contradicts it.

## Proofs

`LeanFmt/Cache/Spec.lean` proves the currency decision sound and complete. `lake build` builds it, so
a broken proof fails the build. The axiom audit does not run in the build.

After you change `Cache/Spec.lean` or `Cache/Decision.lean`, run `#print axioms` over the theorems and
check the output against `results/02-model.md`. A new assumption will not announce itself. Do not mark
a claim verified on the old record.

Do not commit `sorry`, `admit`, or a new `axiom`.

Quantify over the operation you are proving about; do not define it. A proof about "whatever the cache
returns" says nothing. Carry an assumption as a hypothesis, not an axiom. Show that the hypotheses can
hold together, as `serves_hits_somewhere` does, or the theorem is empty.

## Comments

Comment what the code does not state: why a step is needed, which constraint it serves, an invariant,
a convention. Do not restate the code or name the declaration again. A docstring tells a caller what a
declaration means and how to use it.

## Names

Name a public declaration for what it is in the product, not for its place in a proof or a call chain.
Do not use `helper`, `tmp`, `plumbing`, or a public `aux`. If several declarations repeat one
construction, name the construction.

## Options and unsafe

Do not commit a `set_option` in a production module. FMT010 reports them in the code we format, and
the rule holds here too.

`unsafe` is confined to `LeanFmt/Analysis.lean`, where the frontend requires it. A new `unsafe`
anywhere else needs a reason in the commit.
