# Next Proof Packet

- Stack: ruff-05b-semantic-facts
- First unresolved: 02-impl
- Claim ID: RSF-IMPL
- Prompt: 02-impl
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RSF-IMPL**: build what `RSF-SPEC` specified — `Tier.semantic` in the engine, `ModuleArtifact` schema `v4` carrying the semantic fact, and the declared notation/atom spacing captured at the **on-demand `analyzeExact` producer** where `getEnv` is live — as immutable serializable data, preserving the source/syntax fast paths under demand-gating.
- > **RSF-SPEC settled two points this prompt's earlier draft got wrong** (`notes/01-semantic-facts.md` > §1, `results/01-spec.md`); build to these, not to the older wording: > - **Source of the gap: the registered formatter, not the token table.** The parser trims the symbol >   (`Parser/Basic.lean:1114`), so the token table holds `"+"`; only the notation's formatter carries >   the untrimmed `" + "` pp-hint (`PrettyPrinter/Formatter.lean:442-446`). Capture reads the formatter >   (the parser's inverse), never the token table. > - **Location: `analyzeExact`, not the always-on plugin.** Both producers have a live `Environment` >   (`Analysis.lean:77`; `CompilerPlugin.lean:27`), but capturing at the always-on plugin would run a >   formatter probe in every integrated build — the exact always-on tax demand-gating forbids. The >   plugin keeps emitting `semantic = none`; `analyzeExact` captures `some` only under demand.
- Read `roadmap.md`, `notes/01-semantic-facts.md` (the chosen design), the prerequisite stack results, `AGENTS.md`, and the relevant Lean compiler sources. Do not re-open the representation decision; build the one `RSF-SPEC` chose.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No live `Environment`, `CoreM`, or elaborator handle crosses the producer boundary.
- The plugin's import closure and Lake glob must not grow; stop and record if the lookup demands it.
- A missing/undecodable semantic fact is an ordinary miss that degrades to conservative bytes, never a crash or invented spacing.
- Stop rather than weakening exact semantics, cache identity, write safety, or the resource envelope.
