---
claim_id: ECV2-MODES
status: planned
depends_on: [ECV2-CACHE]
---

# Add product modes and conservative writes

## Task

Add `format`, `diff`, `fix`, `rules`, `clean`, and compiler-integration setup/status over the same
semantic result used by check.

## Target

- Check, format, and diff never write source; fix is the only source-writing mode.
- Range and conflict checks are atomic and unconditional; fix writes only output validated under the
  exact identity represented by its result.
- Configuration, ignore/selection, statistics, cache controls, and `--max-memory` express user intent,
  not worker strategy.

## Check

- Golden and property tests cover reversibility, overlap rejection, stale artifacts, rejected
  validation, unchanged files, and every mode's write behavior.
- `lake build`
- `git diff --check`
