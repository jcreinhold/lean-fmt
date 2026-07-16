# Prompt 05 compiler-artifact gates

Date: 2026-07-15

## Local semantic and ownership gates

```sh
LEAN_NUM_THREADS=1 lake -R build lean-fmt lean-fmt-tests artifactExtractor
LEAN_NUM_THREADS=1 lake -R build LeanFmtCompilerPlugin:shared
LEAN_NUM_THREADS=1 lake -R build +LocalSyntax:leanFmtArtifact
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
tests/compiler/run.sh
git diff --check
```

| Gate | Result |
| --- | --- |
| Production and test `.lean` sources begin with `module` | pass |
| Ordinary root import exposes application declarations | none; only executable `main` declarations are public |
| Plugin library exposes private modules with `allowImportAll` | no |
| Custom and file-local syntax projection | pass (`commandEmit_local_command`) |
| Exact UTF-8 source ranges and configured rule result | pass |
| Frontend failure creates an `.olean` payload or facet output | no; `Broken` produces neither |
| Later code-generation failure publishes a facet | structurally no; the facet depends on the successful `leanArts` job even if Lean left an unaccepted `.olean` |
| Payload channel is an undeclared candidate file | no; payload is a silent entry in Lean's persistent lint log |
| Sidecar publication is a post-hoc copy | no; the facet owns extraction and its declared output in one build action |
| Up-to-date module/facet replay preserves the result | pass |
| Configuration participates in the real module trace | pass; toggling `leanFmtTrailingWhitespace` changes the module trace and payload |
| Plugin identity participates in the real module trace | pass; rebuilding a semantically equivalent plugin with a changed binary changes the module trace and rebuilds the facet |
| Source changes invalidate module and facet | pass |
| Extractor ambient search path can substitute a same-named module | no; a shadow `LocalSyntax.olean` first on `LEAN_PATH` does not alter extraction from the exact facet-provided `.olean` |
| Corrupt `.olean` accepted | no; supported import rejects it; removing module output and trace reproduces it |
| Corrupt/partial/missing sidecar accepted | no; trusted facet reader recomputes the content hash and validates schema/module/source digest/source byte count |
| Interrupted atomic write damages committed output | no |
| Declared facet output restores through Lake's cache | pass; an isolated writable cache restores a deleted local JSON artifact without rerunning extraction |
| Facet cache scope and output directory have the same owner | pass by inspection; both derive from `mod.pkg`, while cross-package execution is not a runtime-tested claim |
| Facet result is a raw path | no; the facet returns `Lake.Artifact` and the private reader recomputes content hash plus module/full-source identity |

`Lake.Artifact` is publicly constructible and is not authority by type alone. Prompt 06 must keep
fetch and read in one private Lake-owning operation. The former caller-supplied exit code, setup
path, plugin path, trace-shaped JSON validator,
candidate directory, and absolute source identity are absent.

Lean's persistent lint-log envelope inside the compiler `.olean` still contains Lean's diagnostic
file metadata, including the compilation location. No portability claim is made for that internal
compiler artifact. The extracted sidecar omits the path and is the platform-independent cached
representation.

## Frozen differential and performance sample

```sh
experiments/profile-run.sh --name module-artifact-v2-sample \
  --project-root ~/Code/mathlib4 --build-state ordinary-built \
  --cache-state formatter-cache-cold \
  --sources experiments/workloads/mathlib-v4.32.0-sample.txt -- \
  experiments/run-module-artifact-sample.sh ~/Code/mathlib4
```

- lean-fmt revision at measurement start: `b56fb88f1fb9983d1d4c51fa6a0664799a57bb7b`
  plus the uncommitted Prompt 05 implementation under audit.
- mathlib revision: `783ccda4ee524f13cc5636237be0a1942bc04824`.
- toolchain: `leanprover/lean4:v4.32.0`.
- workload: frozen 62-file sample, digest
  `1936bdb60e01c14fdc986a535ef9317d63775506708e35f4155a9c4c5c6eeeef`.
- result: 62/62 exact command projections equal.
- plain total: 145,862.001 ms; plugin total: 145,885.268 ms.
- paired plugin delta: +23.267 ms total; +0.375 ms mean; +5.937 ms median.
- supported `.olean` extraction: 49,081.540 ms total; 791.638 ms mean; 715.994 ms median.
- sidecar size: 3,451.8 bytes mean; 15,598 bytes maximum.
- plugin `.olean` growth: 4,125.5 bytes mean; 16,296 bytes maximum.
- guarded harness wall: 556,164 ms for three independent frontend passes plus extraction.
- peak aggregate RSS: 2,157,936 KiB; pressure level remained `1`; swap delta: 0 KiB;
  hard stop: none.
- profile output digest:
  `b8b2eebd07c53b1ab17f20df674fa19f6b93f50b87b813bc998c4810a1965dcc`.

Raw records are ignored under
`experiments/results/module-artifact-v2-sample-20260715T232923Z*` and
`experiments/results/module-artifact-sample-20260715T232923Z/`. The stable command and complete
measurements above are the committed evidence.

## Independent audit

The first post-design audit rejected exact-module binding, compacted-region lifetime, package/path
ownership, descriptor authority wording, and missing cache/plugin evidence. After those findings
were repaired, the focused final audit returned **PASS** with no P0, P1, or P2 findings. In
particular, it confirmed that the explicit `ImportArtifacts` binding selects the facet-provided
`.olean`, compacted data remains live for the extractor process, facet output and cache scope both
derive from `mod.pkg`, and the private reader independently validates the descriptor and payload.
