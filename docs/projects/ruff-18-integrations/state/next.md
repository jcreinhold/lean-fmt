# Next Proof Packet

- Stack: ruff-18-integrations
- First unresolved: **none — this stack is complete**
- Claim ID: (both verified: RDI-RECIPES, RDI-FINAL)

## Nothing to run

Both prompts are verified. `results/01-recipes.md` and `results/02-acceptance.md` carry the evidence,
and `state/current.md` records what shipped and what stayed limited.

Do not open a new prompt in this stack to chase the two standing limitations. Neither is unfinished
work:

- **No recipe has run on a GitHub runner.** Closing it requires a code-scanning upload — remote state
  this stack's stop rules forbid. It is recorded as a limitation, not a gap.
- **`actions/cache` mtime preservation is inferred one step** from its use of `tar`. Same blocker.

## If you are here because something broke

`tests/ci/run.sh` is the gate. It reads **committed** state only, so commit first. It fails when:

- a published recipe in `docs/ci.md` stops working;
- a clean run stops writing a SARIF log, or an exit-2 run starts writing one;
- `--changed-since` loses its subset behavior or its empty-selection notice;
- cache identity changes such that an mtime-preserving restore no longer hits, which would make
  `docs/ci.md`'s caching instruction silently wrong;
- `git archive` stops carrying something a build needs.

Fix `docs/ci.md` and the suite together. The document and the suite are one artifact.

## What was cut, and where it would go

`roadmap.md` §"Scope" cut shell completions, pre-commit manifests, and first-party editor packages.
Reopening any of them is a **new stack**, not an amendment here. Completions are the largest unbuilt
piece: a command model, four emitters, and a drift test.
