---
kind: result
claim_id: RMR-SPEC
status: verified
---

# RMR-SPEC — the semantic-rule catalog, characterized and specified

The rule-facing semantic facts are characterized against the pinned Lean 4.32.0 compiler, four
semantic-tier rules are selected on facts with stable machine-readable identity and exact ranges, and
the projection, demand-gating, cache identity, and rule-engine interface are specified precisely enough
for RMR-IMPL. The design is `notes/01-authority.md`; the first-hand compiler evidence is
`evidence/01-semantic-diagnostics.txt` (reproducible from `evidence/fixtures/`). No tier, schema, or
rule code ships in this prompt — the same discipline RSF-SPEC held.

## What was decided

- **Two mechanisms, one chosen for the first cut.** A semantic rule either *surfaces* a diagnostic the
  compiler already emitted (stable `kind` tag + exact range, normalized from the MessageLog we already
  collect) or *owns* it (re-derived from `Environment` data + info-tree occurrence resolution). The
  inventory (`notes/01-authority.md` §2) shows only deprecation is genuine queryable `Environment` data,
  and even it needs the info-tree walk for a structured fix. **All four shipping rules are surfaced**;
  the owned/fixable FMT014 autofix is fully specified but deferred behind the info-tree-capture pitfall
  (§8).
- **Four rules, all empirically firing on v4.32.0, all default-on options, shipped default-OFF**
  (consistent with FMT008–013): FMT014 deprecated-declaration use (`Lean.Linter.deprecatedAttr`),
  FMT015 unused variable (`linter.unusedVariables`), FMT016 unused section variable
  (`linter.unusedSectionVars`), FMT017 constructor-name variable (`linter.constructorNameAsVariable`).
- **`linter.extra.unreachableTactic` rejected** — `defValue := false`, would never fire on a stock
  build.
- **Monolithic `.semantic` capture (Design A)** for now: both sub-facts (notation spacing, diagnostics)
  are cheap, so a `.semantic` artifact stays complete and `Tier.satisfies`/`cacheHitServes` remain a
  sound gate with no capability axis. The capability split (Design B) is reserved for when the deferred
  info-tree walk makes a sub-fact expensive.

## Commands and raw evidence

Toolchain `leanprover/lean4:v4.32.0`; lean-fmt `bf3116d`; `Darwin arm64`. Full transcript in
`evidence/01-semantic-diagnostics.txt`.

- `lake env lean --json evidence/fixtures/Diagnostics.lean` — the four diagnostics fire on a stock
  build, each with a distinct stable `kind` and exact `pos`/`endPos`:

  | kind | severity | range (1-based line:col) | over |
  | --- | --- | --- | --- |
  | `Lean.Linter.deprecatedAttr` | warning | L9:20–L9:27 | the `oldName` occurrence |
  | `linter.unusedVariables` | warning | L12:15–L12:16 | the binder `x` |
  | `linter.unusedSectionVars` | warning | L17:0–L17:47 | theorem `header.ref` |
  | `linter.constructorNameAsVariable` | warning | L21:13–L21:17 | the binder `true` |

- `lake env lean evidence/fixtures/DeprecationEntry.lean` — the structured entry is queryable from
  `Environment` data (the owned-autofix substrate): `newName?=(some newName) since?=(some 2024-01-01)
  text?=none`.

- Source grounding (read first-hand, cited in the note): deprecation attribute/entry/query
  `Linter/Deprecated.lean:24-62`, imported-decl retention `Attributes.lean:295-305`, emit range
  `TermElabM.lean:2111-2113`; `logLint` double-tagging `Linter/Init.lean:133-160`; option defaults
  (`linter.deprecated`, `.unusedVariables`, `.unusedSectionVars`, `.constructorNameAsVariable` all
  `true`; `.extra.unreachableTactic` `false`); info-tree occurrence `InfoTree/Main.lean:344-353`;
  per-command info reset `Command.lean:642-643`; whole-file trees `Frontend.lean:118-122,357-358`;
  message structure `Message.lean:44-46,510-538`.

- Live-code re-read (not trusted) confirming the foundation and the seams RMR-IMPL extends: `Tier` and
  the engine `Rules.lean:35-114,691-703`; `demandedTier` `Config.lean:291,302-303`; `cacheHitServes`
  `Application.lean:449-459`; artifact schema `ArtifactModel.lean:100-158`; semantic-result schema
  `Semantic.lean:26-78`; the notation-capture producer `Analysis.lean:16-20,88-146`.

## Checks

- Structural checker and generated-next check — run below; recorded in `state/current.md`.
- `git diff --check` — clean (docs, fixtures, and evidence only; no production `.lean` changed, so no
  `lake build`/suite run is owed by this prompt, matching RSF-SPEC).
- `tests/boundary/run.sh` is unaffected: this prompt adds no import and no glob; RMR-IMPL owns the
  boundary re-check when the projection field and rules land.

## Remaining uncertainty (carried into RMR-IMPL)

- `endPos = none` (whole-line) range recovery via the `FileMap` line-end fallback — specified, unpinned.
- Clamping surfaced ranges to the module's own byte span so a macro-reattributed position
  (`DeprecatedSyntax.lean:56-59`) never yields a finding off the file.
- Suppression (`FMT900`/`FMT901`) applying to surfaced findings by code — expected to work unchanged
  since the finding carries a lean-fmt code; RMR-IMPL confirms.
- The owned/fixable FMT014 and its whole-file info-tree capture (`notes/01-authority.md` §8) — the one
  genuinely heavy piece, deliberately deferred so the surfaced first cut is proven before the info-tree
  producer change and the Design-B capability split land together.

## Status

RMR-SPEC: **verified.** The catalog is characterized on facts with stable identity and exact ranges,
demonstrated firing first-hand on the pinned toolchain, and the projection/cache/interface is specified
without shipping a tier, schema, or rule change. RMR-IMPL can build the four surfaced rules and the
`v5` diagnostics projection on the `Tier.semantic` / `ModuleArtifact` foundation this freezes.
