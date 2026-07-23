# Native layout route selection

This experiment selected direct transformation of Lean's public `Std.Format` tree. It calls the live
registered formatter on the actual command, aligns non-comment text leaves with source-covering
terminals, substitutes original token payloads, and retains native groups, fill behavior, nesting,
alignment, and tags. The independent formatter oracle reparses two passes and compares imports,
terminal spellings, comment payload/physical ownership, normalized structure, source-map coverage, and
idempotence.

The rejected prototype lowered every `Std.Format` constructor into an isomorphic private tree and then
converted it back. It produced byte-identical output at widths 24, 40, 60, and 100, but allocated one
additional node per native node: 431 extra nodes on `fixtures/LayoutCore.lean` and 13,928 on
`Mathlib/CategoryTheory/Action/Basic.lean`. Its wall/RSS measurements had no compensating improvement.
The lowering implementation was deleted after `selection.json` was recorded.

The probe also records two safety boundaries that production must improve rather than silently widen:

- Lean reparents multi-step tactic and guarded-`let` sequences under native whole-command rendering.
  The experiment protects those syntax ranges as exact islands; Prompt 24b must compose independently
  native-formatted sequence items at their owner indentation before production cutover.
- Lean throws on some pseudo-antiquotation kinds and can indent inside multiline token payloads. Those
  typed syntax-data commands remain exact; original-token alignment protects every ordinary token.

The first 24 paths in `../workloads/mathlib-v4.33.0-rc1-stratified.txt` all changed and passed the
two-pass oracle at width 80. `failure-manifest.tsv` maps the earlier 15 failures to a minimized fixture
or explicit safety owner. `selection.json` pins commits, digests, counts, and the representation choice.

Run `run.sh` for the checked-in fixtures and named stress cases. Set `LEAN_FMT_ROUTE_FIRST24=1` to run
the bounded 24-file oracle; it never writes mathlib sources.
