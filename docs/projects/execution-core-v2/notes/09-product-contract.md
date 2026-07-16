# Product-mode and edit boundary

Date: 2026-07-15

## Why Prompt 09 needed repair

The original prompt named six capabilities but left their observable behavior and safety boundary
to the executor. In particular, it did not define what `format` emits, whether compiler setup edits
an executable Lake program, how external rule selection relates to semantic cache identity, or what
must happen between preparing an edit and publishing it. Those are architectural choices, not small
implementation details.

The repair keeps one coherent product prompt but gives it two explicit major steps: first the deep
edit capability, then modes and configuration over the existing application transaction.

## Chosen boundary

The semantic result is canonical and strategy-independent. Include/exclude filters choose files;
select/ignore and per-file ignores project findings after analysis. They do not change frontend
construction or create strategy-specific cache entries. The application owns that projection so
artifact hits, result-cache hits, and exact fallback cannot diverge at the CLI layer.

A patch is not an array of hopeful replacements. Its constructor consumes the exact immutable source
snapshot and either returns complete checked output or one typed rejection. It hides range ordering,
UTF-8 boundaries, overlap detection, and assembly. The write transaction then performs exact
validation on the proposed complete source, verifies that disk still equals the snapshot, and uses a
same-directory atomic rename. Callers cannot perform those steps in a different order.

## Compiler integration

`lakefile.lean` is executable Lean, so a general-purpose formatter cannot soundly splice declarations
into it by textual convention. `compiler setup` therefore emits deterministic, versioned integration
guidance rather than mutating the target. `compiler status` evaluates the target workspace and audits
toolchain compatibility and trusted module-artifact coverage without building or publishing. The
module system and Lake retain ownership of plugin setup, compilation success, traces, and artifact
publication.

This is a deliberate deep interface: the user asks for setup guidance or status, while the product
does not expose extraction jobs, facet paths, plugin load order, cache identity, or process strategy.

## Validation levels

The current exact fallback uses Lean's full frontend, so it is acceptable for the default safe-write
gate to be stronger than a future syntax-only implementation. It is not acceptable to label a weaker
approximation as exact syntax validation. `--check-elab` remains a distinct semantic identity and
must select an elaborating gate; later performance work may add a genuinely syntax-only primitive
without changing the edit transaction.

## Output and failure semantics

Preview modes never write. `format` exposes complete proposed source, while `diff` exposes a stable
unified diff. `fix` is the only `.lean` source writer. A per-file rejection leaves that file unchanged
but remains report data so other selected files are not silently dropped. Request or workspace
failures exit 2; findings, broken files, or rejected fixes exit 1; successful clean and fix outcomes
exit 0.
