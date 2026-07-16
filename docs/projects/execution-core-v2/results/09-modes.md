# ECV2-MODES result

Status: verified on 2026-07-15.

## Delivered product surface

`lean-fmt` now provides `check`, `format`, `diff`, `fix`, `rules`, `clean`, `compiler setup`, and
`compiler status` with deterministic text/JSON output, strict configuration, rule projection,
statistics, semantic cache controls, elaboration validation intent, and an aggregate memory envelope.
No command exposes worker count, pinning, environment reuse, or another execution strategy.

Preview commands never write. `fix` consumes the same canonical analysis as preview, prepares one
all-or-nothing UTF-8 patch, validates the complete candidate under the exact target module setup,
rejects stale source, preserves permissions, and publishes atomically per file. Rejected validation,
conflicts, and staleness produce report data without dropping other files.

## Deep boundaries

- `LeanFmt.Application.execute` owns the semantic transaction and accepts only user intent.
- `LeanFmt.Cli` owns parsing, rendering, statistics, and exit mapping.
- `LeanFmt.Config` owns strict TOML, normalized globs, selector precedence, and per-file projection.
- `LeanFmt.Edit` owns complete range/UTF-8/conflict validation, assembly, identity, and inversion.
- Compiler setup is deterministic guidance rather than an unsafe Lake-source rewrite; compiler status
  is a bounded read-only artifact audit.

The exact fallback was also tightened: an incomplete diagnostic-only setup may report a broken
header/import, but it cannot yield a successful result or authorize a write.

## Evidence

See [the Prompt 09 gate](../evidence/09-modes-gates.md). Unit, compiler, check, product-mode, module,
stack-structure, generated-next, and diff gates passed sequentially. The product-mode suite proves
byte-identical artifact/fallback/cache projections, all preview/write contracts, rejected validation,
stale detection, permission preservation, configuration precedence, read-only compiler status, and
clean scope. A separate temporary Lake package also required this checkout, loaded
`@lean_fmt/LeanFmtCompilerPlugin:shared`, and built `+Downstream:leanFmtArtifact`, validating the
setup guidance beyond the repository's own fixture. Full mathlib was intentionally not run at this
stage.
