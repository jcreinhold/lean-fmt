# Module-system correction for compiler artifacts

## The rejected boundary

The first compiler-artifact implementation accepted a candidate path, setup path, plugin path, and
scalar exit code independently. Hashing those inputs after a process exited did not prove that they
belonged to the invocation that wrote the candidate. Moving the copy behind a `leanArts` dependency
did not repair the association: the candidate was still an undeclared side effect that Lake could
not restore from cache or bind to the successful job.

The corrected design has no candidate and no promotion operation.

## Representation comparison

| Representation | Result |
| --- | --- |
| Ordinary `.ilean` | Rejected. Lean 4.32 retains module/import/reference/declaration metadata, not the exact command syntax and byte ranges needed by formatter rules. |
| A custom `ModuleEnvExtension` | Rejected. A `ModuleLinter` runs under state restoration, so adding a custom entry there does not transparently persist it. Reading opaque extension entries directly would require unsupported casts. |
| Lean's persistent lint log | Selected as the compiler-owned source of truth. Lean 4.32's frontend records tagged linter messages into `Lean.Linter.lintLogExt` only after error-free elaboration and immediately before `.olean` serialization. It has a supported `getAllLints` reader. |
| Lake facet sidecar | Selected as the compact consumption form. Its build action imports the exact successful `.olean`, extracts the persistent formatter record, and atomically creates the declared sidecar. The action, extractor executable, `.olean`, and output hash are one Lake job graph. |

The selected design deliberately combines the two supported layers. The persistent lint entry makes
compiler success and payload provenance inseparable. The facet turns that entry into a small
content-addressed result without asking ordinary application callers to import a frontend
environment.

## Ownership chain

1. `LeanFmtCompilerPlugin` receives the exact module command array and source file map.
2. It computes the compact command projection and rule findings in-process.
3. It emits one silent, tagged linter message containing the compact JSON payload.
4. Lean's own `recordLints` persists that message only after the frontend has established that the
   module has no errors.
5. `.olean` serialization owns the payload together with the exact toolchain, imports, options,
   plugin, and dependency environment that produced it.
6. The `leanFmtArtifact` Lake facet depends on both that `.olean` and the extractor executable. Its
   action binds the exact facet-provided `.olean` into the supported import API and atomically
   writes the declared sidecar. Ambient search-path precedence cannot substitute a same-named
   module.
7. The future Lake-owning orchestration consumes the returned `Lake.Artifact` immediately,
   recomputes its content hash without trusting an adjacent `.hash` accelerator, validates the
   schema/module/full source snapshot, and treats every failure as a miss. `Lake.Artifact` is a
   public descriptor, not unforgeable authority; the reader therefore remains private and must not
   become a caller-facing API.

There is no independently supplied path-and-identity API. The artifact does not claim a validation
enum: successful `.olean` ownership is the validation fact. It also omits an absolute source path,
which would make otherwise identical artifacts workspace-location dependent.

Lean's persistent lint-log wrapper does retain the compiler diagnostic's source filename in the
`.olean`; that implementation artifact is therefore not claimed to be location-independent. The
extracted formatter sidecar deliberately omits the path. Its Lake facet runs under the owning
package context, derives its output directory from that package's build directory, declares a
`.json` artifact, and has been restored from an isolated writable Lake cache after deleting the
local output. This keeps same-named modules in distinct packages from sharing a sidecar or trace
path; the fixture exercises the root-package case, while the cross-package isolation follows from
the path construction and is not separately claimed as a runtime test.

## Module and plugin packaging

Every ordinary production and test `.lean` source begins with `module`. `LeanFmt` exports no
application declaration; internal reach uses `import all` within the package. The separate
`LeanFmtCompilerPlugin` root is the only registration root of the loadable plugin. Downstream users
cannot import private implementation modules merely because the plugin library needs them:
`allowImportAll` is not enabled.

## Measured result

The frozen 62-file mathlib sample ran three independent exact frontends per file: plain, production
plugin, and differential-oracle plugin. A fourth phase imported the plugin-produced `.olean` and
extracted its persistent formatter record.

- 62/62 command kind/range projections matched the independent oracle.
- Plain and oracle `.olean`s were byte-identical. Plugin `.olean`s intentionally differed because
  they own the formatter record.
- Plain frontend total: 145,862.001 ms.
- Plugin frontend total: 145,885.268 ms.
- Paired plugin delta: +23.267 ms total, +0.375 ms mean, +5.937 ms median.
- Supported extraction: 49,081.540 ms total, 791.638 ms mean, 715.994 ms median.
- Sidecars averaged 3,451.8 bytes and reached 15,598 bytes.
- Plugin `.olean` growth averaged 4,125.5 bytes and reached 16,296 bytes.
- The guarded four-phase harness took 556.164 seconds, peaked at 2,157,936 KiB aggregate RSS,
  remained at macOS pressure level 1, and added no swap.

This is representation and callback evidence, not a full-check timing. The supported import reader
is sound but its per-module process/import startup is not cheap enough to assume at mathlib scale.
Prompt 06 must design consumption twice and measure whether extraction can be batched or avoided
without accumulating frontend environments or weakening the module boundary.
