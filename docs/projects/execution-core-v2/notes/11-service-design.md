# Editor service design: serialize intent over the accepted exact primitive

## Source-truth correction

The planned editor service cannot simply call the batch operation. `execute` snapshots on-disk files,
may use current ordinary outputs, compiler artifacts, or persistent cache entries, and owns report
aggregation and fix publication. An editor supplies unsaved bytes. Reusing an on-disk witness for
those bytes would be unsound, while writing them temporarily into the project would introduce stale
state, watcher races, and a second publication protocol.

The reusable semantic primitive is narrower: analyze one immutable source snapshot under the exact
existing target's Lake setup and canonicalize the result. Batch fallback and the service can share
that operation without sharing their orchestration. A bracketed analysis run pulls child lifecycle,
temporary setup/source material, toolchain environment, unique naming, one-thread policy, and memory
accounting below both callers. Each request still receives a fresh process, so process exit supplies
the reclamation and crash boundary already accepted by Prompt 10.

## Designs compared

1. **Call batch `execute` per editor request.** Rejected: it rereads disk, cannot represent unsaved
   source, entangles persistent cache/evidence selection with editor semantics, and reloads the
   workspace.
2. **Retain an in-process Lean frontend session.** Rejected: earlier exact-context retention crossed
   8 GiB within six distinct files, mutable environments invite accumulated-grammar semantics, and a
   crash would kill the editor service.
3. **One service process plus fresh exact children.** Selected: the service retains cheap evaluated
   project/configuration data and version numbers, while every unsaved analysis shares the accepted
   exact child primitive and exits under the aggregate envelope.

## Protocol depth

`LeanFmt.Service` owns framing, private wire DTOs, path/version state, stable protocol errors, FIFO
sequencing, and response flushing. It does not own parsing, rule execution, compiler setup, validation,
cache identity, child supervision, or source writes. `LeanFmt.Cli` adds only the `serve` command and
its startup options.

The queue is defined away rather than modeled as a concurrent subsystem: read one line, finish and
flush one response, then read the next. This is a capacity-one application queue with operating-system
pipe backpressure. It proves FIFO ordering and bounded retained requests without a reader task,
channel, lock, cancellation protocol, or a `busy` state whose timing would be nondeterministic.

Version state is one natural number per normalized path. It advances when a structurally valid analyze
request is accepted, before expensive analysis, and never stores prior source text. This makes stale
requests cheap and ensures an infrastructure failure does not reopen an older version.

## Error model

Protocol mistakes are response data, not service exceptions. Malformed JSON has no trustworthy ID and
therefore responds with `null`; valid JSON preserves any ID exactly. Unknown paths and stale versions
do no compiler work. Exact child crash/resource exhaustion becomes one `analysis-failure` response and
the next request remains process-isolated. Only failure to initialize the exact project/toolchain or
write protocol output terminates the service as infrastructure exit 2.

Input is bounded at two layers: 32 MiB per JSON line and 16 MiB per source. The stream API may allocate
the incoming line before it can be rejected, but the application retains at most one such line and
never accumulates a queue; the focused RSS test therefore validates the actual bound of the chosen
Lean runtime interface.

## Retained implementation

`Application.ExactRun` is the bracketed capability selected above. It fixes the evaluated project,
current executable, aggregate byte envelope, private temporary directory, and collision-free request
counter. Its constructor and fields are inaccessible. Each `analyzeSnapshot` writes private setup and
source inputs, starts one exact-toolchain child with one Lean thread, canonicalizes its response, and
removes both inputs in a `finally` block before returning. The bracket removes its directory under all
exit paths. Batch first resolves cache, ordinary module evidence, and official artifacts; it constructs
an `ExactRun` only if a true frontend miss or fix validation remains.

`Project.Snapshot.findTarget?` owns realpath normalization, root containment, and selected-source
membership. `SourceTarget.withSource` is the only replacement-byte constructor exposed to internal
callers, preserving canonical path/module identity. `Service` then owns only wire decoding, version
state, response projection, and the read/process/flush loop. Its exact check calls
`ExactRun.checkSnapshot`, which uses the same canonical analysis and rule/report projection as batch.

The focused 100-request run confirmed the design experimentally: 44.388 seconds, 1,041,472 KiB peak
parent-plus-descendant RSS, normal macOS pressure, zero swap growth, and parent median RSS decreasing
from 800,496 KiB in the first ten responses to 723,776 KiB in the last ten. No retained frontend
session, concurrent queue, cache write, or source write exists.
