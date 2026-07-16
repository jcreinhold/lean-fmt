---
claim_id: ECV2-SERVE
status: planned
depends_on: [ECV2-SCALE]
---

# Add editor service after batch acceptance

## Read

- `roadmap.md`, `state/current.md`, `notes/06-design.md`, `notes/09-modes-design.md`,
  `notes/10-scale-design.md`, and `notes/11-service-design.md`.
- `LeanFmt/Application.lean`, `LeanFmt/Cli.lean`, `LeanFmt/Project.lean`,
  `LeanFmt/Semantic.lean`, and the focused check/mode integration harnesses.

## Repair prerequisite: extract one snapshot-analysis capability

Batch execution currently hides exact fallback and canonical projection inside `execute`, but an
editor request carries unsaved bytes and cannot safely call the filesystem batch command or pretend
that the current `.olean`, formatter artifact, or result cache describes those bytes.

- Pull the exact child lifetime, temporary setup/source paths, per-request unique naming, target
  toolchain environment, one Lean thread, and aggregate memory enforcement behind one bracketed
  analysis-run capability. Opening the capability returns only valid prepared state and cleanup is
  guaranteed by the bracket; callers never receive raw setup/temp paths or sequence close/restart.
- Define one internal snapshot-analysis operation that takes an existing exact project source target
  with replacement immutable bytes and returns the same canonical `SemanticAnalysis` used by batch.
  Batch fallback and service analysis must both call it. Do not invoke `execute` recursively, write
  unsaved bytes into the project, or create a second parser/projection pipeline.
- Unsaved editor bytes always use fresh exact-context analysis. Existing ordinary `.olean`s,
  formatter facets, and persistent result-cache entries describe the on-disk snapshot and cannot
  authorize replacement bytes. Process exit remains the reclamation and crash-isolation boundary.
- The service may load and retain one project snapshot and configuration. Requests are serialized;
  it does not retain a mutable Lean frontend environment or permit concurrent use of an analysis run.

## Product protocol

Add `lean-fmt serve [--root PATH] [--config PATH] [--select SELECTOR] [--ignore SELECTOR]
[--max-memory GIB]`. The command reads one UTF-8 JSON object per stdin line and writes exactly one
compact JSON response per accepted input line to stdout, flushing after each response. Diagnostics
and logs never contaminate stdout. EOF is a clean shutdown.

The protocol schema is `lean-fmt.service.v1`. Request IDs are arbitrary JSON values and are echoed
unchanged. Protocol DTOs and version state remain private to `LeanFmt.Service`.

- `{"id": ID, "method": "health"}` returns schema, `ready`, target root, and exact toolchain.
- `{"id": ID, "method": "analyze", "path": RELATIVE_LEAN_PATH, "version": NAT,
  "source": STRING}` returns the same path, version, canonical status, findings, and diagnostics as
  batch `check` would produce for those exact bytes and selectors. Paths must identify an existing
  selected project source; they are normalized root-relative paths and cannot escape the root.
- `{"id": ID, "method": "shutdown"}` returns a success acknowledgement and then exits 0 without
  reading another request.

For each path, an analyze version must be strictly greater than the last syntactically valid analyze
request accepted for that path. A stale version returns code `stale-version`, reports the latest
accepted version, performs no analysis, and does not terminate the service. A valid version advances
before analysis begins, so an infrastructure failure cannot later allow an older snapshot to run.

Malformed JSON, missing/wrong-typed fields, unknown methods, invalid paths, oversized lines/sources,
stale versions, and analysis failures each produce one structured error response and leave the
service ready for the next line. Errors use stable codes and messages; malformed input has JSON
`null` as its response ID when no valid ID can be recovered.

## Bounded FIFO and resources

- The application-level queue capacity is exactly one: the loop reads one line, completely handles
  it, flushes its response, then reads the next. Pipelined stdin therefore receives operating-system
  backpressure and responses remain FIFO without a concurrent reader, queue, mutex, or `busy` state.
- Reject a request line above 32 MiB and source text above 16 MiB. Do not retain prior source bodies or
  semantic reports after their response is emitted; retain only the latest version number per path.
- Every exact child is bounded by the command's nonzero aggregate envelope and uses
  `LEAN_NUM_THREADS=1`. Resource exhaustion is a per-request analysis error; the service remains live
  after the child exits. The service never retries above the envelope.
- `serve` never reads or writes the persistent result cache and never writes project source.

## Check

- Unit-test request decoding, response-ID preservation, path normalization, version transitions, and
  stable error codes.
- Add an NDJSON integration suite that starts the release-compatible executable once and proves:
  health; byte-identical findings/diagnostics against independent batch exact fallback; unsaved
  findings; pipelined FIFO ordering; stale rejection without analysis; malformed/unknown/oversized
  recovery; analyzer failure and resource exhaustion recovery; shutdown acknowledgement and no
  post-shutdown request; EOF exit; and no source/cache writes.
- Exercise at least 100 sequential unsaved requests in one process, sampling parent-plus-child RSS.
  The run must stay within the requested envelope with normal pressure/no material swap growth and no
  monotonic retained-source growth. This is a focused service fixture, not a full mathlib run.
- Confirm every compiled service/test source begins with `module`; lakefiles remain the only
  executable-configuration exception.
- `lake build`
- Existing compiler, check, modes, and scale suites.
- Run the deep-module audit, stack structural checker, generated-next checker, and `git diff --check`.

## Stop

Stop for replanning instead of accepting on-disk evidence for unsaved bytes, retaining a mutable
frontend environment across distinct exact headers, adding a second semantic projection or source
writer, allowing unbounded input retention, exposing concurrency controls, or weakening the memory
envelope. Ordinary Lean stream/JSON API drift, a missing focused fixture, and a failed first protocol
test are not blockers.
