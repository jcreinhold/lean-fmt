# Prompt 09 product-mode gates

Date: 2026-07-15

Prompt status: in progress. This file accumulates evidence by major step; it is not yet evidence for
the full `ECV2-MODES` claim.

## Major step 1: checked patches

| Gate | Result |
| --- | --- |
| `LEAN_NUM_THREADS=1 lake build LeanFmt.Edit lean-fmt-tests` | pass; 18 jobs |
| `LEAN_NUM_THREADS=1 lake exe lean-fmt-tests` | pass |
| Range checks | out-of-bounds replacement rejected |
| UTF-8 checks | interior byte position of `α` rejected |
| Conflict checks | overlapping replacements and competing insertions rejected |
| Determinism | reversed adjacent input edits produce the same `AB` output |
| Reversibility property | every ordered pair of five UTF-8 boundaries × three replacements round-trips |

The focused suite also applies the real FMT001/FMT002 output to multibyte source and verifies exact
source-digest matching. No filesystem publication behavior is claimed by this step.
