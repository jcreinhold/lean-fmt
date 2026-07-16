# Sound semantic result cache

Date: 2026-07-16

## Capability boundary

`ResultCache.open?` is the only cache constructor. It accepts an evaluated Lake workspace and the
running application path, then either returns a capability bound to one complete environment epoch
or `none`. Callers cannot supply a cache directory, assemble a partial environment digest, choose a
trace subset, or manufacture an entry path.

The application performs one cache preflight over all immutable source snapshots. If every lookup
hits, it returns before creating a temporary directory. A mixed run carries the preflight results
into ordinary analysis and writes only the misses. Artifact extraction and fresh frontend execution
therefore remain alternative semantic sources below the cache, never identity components.

## Identity

Each entry key includes:

| Component | Authority |
| --- | --- |
| exact source | SHA-256 of UTF-8 bytes |
| toolchain | running Lean version plus target installation Git hash |
| environment | ordered Lean/source/shared/binary paths plus verified Lake traces |
| formatter and rules | SHA-256 of the exact running executable |
| module configuration | package/module identity, evaluated Lean options and arguments, declared plugins/dynlibs, import policy |
| validation | closed `syntax` or `elaboration` value |
| semantic schema | module-artifact schema plus result-cache schema |

The environment epoch walks every non-toolchain Lean search root in order. Every `.olean`, including
its server/private parts, must match the output hashes in an adjacent Lake trace with the expected
toolchain trace schema. Managed shared libraries are checked the same way. Ambient non-toolchain
search roots participate; an untraced artifact disables caching rather than producing a coarse key.

A selected module must itself have a traced `.olean` to use the cache. Its trace binds evaluated
setup, import artifacts, extra targets, options, plugins, and build dependencies into the aggregate
epoch. Sources without their own output remain valid inputs to exact analysis, but this coarse cache
does not claim an identity it cannot prove for them.

## Entry trust and writes

Entries live under `.lean-fmt-cache/results/`, separate from compiler artifacts. Each contains a
cache schema, expected identity digest, semantic-payload digest, and an `AnalysisEnvelope`. Reads
recompute all three layers and validate artifact schema, source digest and byte length, module name,
ranges, and the broken-result diagnostic shape. Parse, schema, digest, identity, or semantic failure
is a miss.

Writes use a process/nonce temporary sibling followed by rename. A partial temporary file cannot
shadow the committed name. Write failure never changes a successful check result; it only leaves a
future miss. `--no-cache` constructs no cache capability and performs neither reads nor writes.

## Warm execution

Workspace evaluation remains mandatory because `lakefile.lean` is executable. It is not a project
source frontend: an all-hit run fetches no per-file setup, imports no target module, and starts no
analyzer or extractor process. Private profiling emits workspace, selection/snapshot, epoch, and
lookup phases to stderr only when `LEAN_FMT_PROFILE_PHASES=1`; normal text and JSON bytes are
unchanged.

The complete mathlib epoch is practical under the warm target. Final measurements are in the Prompt
08 gates. Full 8,795-file warm acceptance remains Prompt 10 because only 62 genuine results currently
exist; no entries were synthesized to make the larger benchmark appear warm.
