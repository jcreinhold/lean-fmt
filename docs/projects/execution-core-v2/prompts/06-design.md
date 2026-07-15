---
claim_id: ECV2-DESIGN
status: planned
depends_on: [ECV2-BUILT-COLD, ECV2-COMPILER-ARTIFACTS]
---

# Select and specify the native Lean architecture

## Task

Use the two measured execution paths to design the production modules twice and select the smallest
boundary that serves ordinary-built cold, formatter-integrated, and cache-warm runs without leaking
strategy into callers.

## Read

- Results of ECV2-BUILT-COLD and ECV2-COMPILER-ARTIFACTS.
- The Philosophy of Software Design chapters on deep modules, information hiding, pulling complexity
  downward, designing twice, and performance.

## Target

- Interface comments and signatures precede implementation.
- One private intent-to-report operation owns workspace discovery, artifact/cache decisions, exact
  fallback, resource enforcement, deterministic collection, and writes.
- Compiler plugin, artifact store, and fallback analyzer expose capabilities, not lifecycle steps.
- The design note identifies any non-Lean component by the exact missing Lean capability or measured
  advantage; otherwise the system remains pure Lean.

## Stop

No public strategy flags, single-implementor traits/typeclasses, pass-through facades, temporal setup
protocols, or caller-visible cache/import sequencing.

## Check

- Run the deep-module audit before and after the skeleton.
- Inspect every caller; common CLI code must not know import or artifact strategy.
- `lake build`
- `git diff --check`
