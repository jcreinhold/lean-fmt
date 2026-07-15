---
claim_id: ECV2-CACHE
status: planned
depends_on: [ECV2-SCALE]
---

# Add a coarse trace-epoch cache

## Task

Cache completed check results behind one coarse, explicit trace epoch. Favor simple invalidation and
worker-free exact hits over a fine-grained dependency model. Cache behavior must be observationally
equivalent to rerunning the oracle.

## Read

- `RunEngine` input discovery, child trace/context identity, and ECV2-SCALE evidence.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/05-information-hiding-and-leakage.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/10-define-errors-out-of-existence.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/20-designing-for-performance.md`.

## Target

- The trace epoch includes the exact toolchain/capability identity, output-affecting configuration
  and rules, protocol version, and child-reported ordered import trace identity.
- Any epoch change invalidates affected stored results as a unit; the cache does not claim dependency
  precision it cannot prove.
- A valid all-hit check reads no Lean child and produces the same reports and exit status.
- Writes are atomic; corrupt or interrupted entries are ordinary misses.

## Stop

Do not reuse across trace epochs. Do not infer import dependency freshness from source names alone.
Do not introduce a public cache API or a graph invalidator.

## Check

- Tests cover every epoch ingredient, source change, corruption, interrupted write, full hit, partial
  miss, and disabled cache.
- Instrument child creation and prove the all-hit path creates none.
- Differentially compare cached and fresh reports.
- Record cold and warm mathlib check times.
- `cargo test -p lean-fmt`
- `git diff --check`
