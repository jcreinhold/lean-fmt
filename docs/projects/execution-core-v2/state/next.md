# Next Proof Packet

- Stack: execution-core-v2
- First unresolved: 06-design
- Claim ID: ECV2-DESIGN
- Prompt: 06-design
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Use the two measured execution paths to design the production modules at least twice and select the smallest deep boundary that serves ordinary-built cold, formatter-integrated, and cache-warm runs without leaking strategy into callers. This prompt selects interfaces and implements only enough skeleton to prove ownership; it does not disguise an unmeasured extraction mechanism as production.

## Reuse

- Results of ECV2-BUILT-COLD and ECV2-COMPILER-ARTIFACTS.
- `LeanFmt/ArtifactStore.lean`, `LeanFmtArtifactExtract.lean`, the `leanFmtArtifact` facet, and the exact fresh-process fallback experiment.
- The Philosophy of Software Design chapters on deep modules, information hiding, pulling complexity downward, designing twice, and performance.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No public strategy flags, single-implementor traits/typeclasses, pass-through facades, temporal setup protocols, caller-visible cache/import sequencing, accumulated/superset grammar, or unbounded batch retention. If no supported bounded extraction path exists, record the precise Lean/Lake facility that is missing and retain the exact process boundary rather than inventing an unsafe shim.
