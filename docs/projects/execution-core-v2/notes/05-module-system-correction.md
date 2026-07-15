# Module-system correction for compiler artifacts

The first compiler-artifact implementation correctly separated a frontend candidate from a
validated artifact, but its promotion operation accepted a candidate path, setup path, plugin path,
and scalar exit code independently. Hashing those inputs after the process exited did not prove they
belonged to the invocation that produced the candidate. It recreated Lake's central invariant in an
unenforced caller protocol.

The corrected design starts from the module system:

- Lean's `module` frontend owns the exact header, visibility, file-local syntax, and elaboration.
- Configured Lake plugins are dependencies of the module setup and therefore participate in the
  module's build trace.
- `leanArts` publishes only after successful compilation.
- A Lake module facet can own a compact derived output under that successful job and its trace.
- `ModuleEnvExtension` can persist one serializable value per module directly in `.olean`, but its
  usefulness depends on whether supported APIs can extract that value without importing the
  transitive environment.
- Ordinary `.ilean` files are cheap JSON, but Lean 4.32 records imports, declarations, and references,
  not the command syntax needed by formatter rules.

Prompt 05 now compares these representations explicitly. It forbids post-hoc trace-shaped JSON
validation and opaque environment-entry casts. The expected choice is a Lake facet unless a measured,
supported persistent-module-data read path is both exact and cheaper.

The bounded compiler-overhead sample was stopped after the design flaw was identified. Its completed
paired rows may inform plugin callback cost, but its promotion timings and publication scheme are not
architecture evidence.
