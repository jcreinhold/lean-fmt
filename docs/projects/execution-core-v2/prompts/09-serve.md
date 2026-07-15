---
claim_id: ECV2-SERVE
status: planned
depends_on: [ECV2-MODES]
---

# Add the long-lived service last

## Task

Expose the completed private execution core through a line-delimited service mode for editors.
Keep one controller owner for `LeanRun`, serialize protocol state, bound queued work, and reuse the
same oracle, cache epoch, memory envelope, and edit validation as command-line modes.

## Read

- Completed `RunEngine`, `LeanRun`, cache, modes, and process-memory behavior.
- Editor protocol requirements in current usage documentation or fixtures.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/07-different-layer-different-abstraction.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/08-pull-complexity-downwards.md`.

## Target

- A private service controller in the `lean-fmt` binary; no library API is introduced.
- Bounded request queue, FIFO mutation of child state, stale document-version rejection, health,
  graceful shutdown, and stdout/stderr protocol isolation.
- Service requests reuse the same check/format core and exact ordered context rules.
- Child rotation or failure cannot let an older response overwrite newer document state.

## Stop

Do not create a second execution engine for service mode. Do not share mutable `LeanRun` across
threads or expose it through a public trait. Do not let queued source snapshots grow without bound.

## Check

- Protocol tests cover check, format, busy, stale, health, malformed input, child rotation, failure,
  shutdown, and concurrent submitters.
- Differentially compare service responses with equivalent command-line results.
- Monitor the complete service process tree under the 8 GiB envelope.
- `cargo test --workspace`
- `git diff --check`
