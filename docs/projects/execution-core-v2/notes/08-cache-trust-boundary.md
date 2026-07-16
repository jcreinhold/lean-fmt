# Cache trust boundary repair

Date: 2026-07-16

## Contradiction found

The original Prompt 08 required a universally semantic cache identity while also requiring an
all-hit run not to load the project environment. Those requirements cannot both hold for a general
Lake project.

`lakefile.lean` is executable Lean. It can choose libraries, module options, plugins, dynamic
libraries, roots, and paths from environment variables or arbitrary IO. A static census of familiar
files cannot prove that evaluating the program again would produce the same workspace. Hashing more
paths only hides this gap; it does not close it.

## Repaired boundary

The application evaluates Lake workspace configuration before trusting result entries. The cache
then hashes the evaluated ordered roots and module context together with trustworthy Lake artifact
traces, target toolchain identity, formatter/rules identity, validation level, artifact schema, and
the exact source snapshot.

An all-hit run remains frontend-free: it creates no Lean analysis environment, imports no project
module, starts no analyzer or extractor child, and does not fetch thousands of `ModuleSetup` jobs.
Lake configuration loading is measured as its own phase rather than being mislabeled a cache lookup.

If a non-toolchain build root lacks the trace information needed to identify its imported artifacts,
the run does not cache. Missing trust is an ordinary disabled-cache outcome, not permission to use a
coarser key.

This matches the earlier product assumption that a warm run may evaluate Lake configuration but
must start no analysis worker. It preserves the under-30-second goal while removing an impossible
proof obligation from the executor.

The prompt also no longer demands a complete mathlib all-hit timing before genuine results exist.
Prompt 08 measures the complete mathlib epoch and real fixture/sample hits. Prompt 10 performs the
8,795-file warm acceptance after a plausible cold path has populated trustworthy entries. Synthetic
entries are not semantic evidence, and a known-implausible cold run is not justified merely to seed
a benchmark.
