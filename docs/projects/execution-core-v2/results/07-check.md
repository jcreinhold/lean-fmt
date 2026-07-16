# ECV2-CHECK result

Status: verified on 2026-07-16 after the exact-path differential, failure matrix, direct-process
resource profile, repository gates, and module-boundary audit.

## Result

`lean-fmt check` now executes one private intent-to-report transaction over exact Lake modules. It
resolves the target root's Lean installation without a wrapper process, rejects version or Git-hash
mismatch, snapshots each selected source once, consumes only source-validated module artifacts, and
falls back to a fresh exact frontend child. Both execution paths produce byte-identical deterministic
reports.

Check never writes source. Syntax/import failures are path-sorted file data; infrastructure failures
are aggregated without omitting other files. Exit codes are `0` for clean, `1` for findings or broken
files, and `2` for infrastructure failure.

The fallback uses one Lean thread, an allocator ceiling, and a 50 ms parent-plus-child RSS monitor.
The direct product process reduced the measured one-file peak from about 1.3 GiB under `lake env` to
about 0.65 GiB. Whole-run artifact and scale enforcement remains Prompt 10 work and is not claimed
here.

## Evidence

See [the vertical-slice design note](../notes/07-check.md) and
[Prompt 07 gates](../evidence/07-check-gates.md). No full-mathlib run was needed.
