# Artifact syntax design probe

Prompt 17 feasibility probe. It runs the target project's exact `ModuleSetup`, captures the parsed
header/command/terminal stream, serializes every syntax constructor into a compact source-backed preorder CST, parses
and decodes the wire bytes, and requires `Syntax.eqWithInfo` for every root. It also compares registered command
formatter output at widths 40 and 100 under both the command's live environment and the final module environment.

The codec retains all `choice` alternatives. Original atom text and identifier raw substrings are recovered from the
identity-matched normalized source; node kinds are interned. Identifier `Name` and preresolution data remain explicit.
Effective command `Options` are encoded as a deduplicated table, including every public `DataValue` constructor;
syntax-valued options recursively use the same codec. The registered formatter comparison uses decoded syntax and
decoded options, not the originals.

`OptionProbePlugin.lean` establishes the compiler hook and rejects an unsafe aggregation idea. The end-of-module linter
receives only the terminal command's info tree and cannot reconstruct option history. A regular linter receives each
command's `CommandContextInfo`, including its effective options; the fixture distinguishes `pp.universes := true` and
`false`. But regular linters are async: even a mutex-protected process-global carrier map contained only two of five
command/terminal records when the module linter ran. Production must therefore persist one independently valid record
per command and let the Lake facet validate, sort, and compact those records. It must not rely on a later in-process
collector seeing all earlier linter tasks.

`run.sh` rebuilds the probes, demonstrates the negative/positive extension-loading boundary, runs the hard fixtures, all
45 lean-fmt sources, and the current five-file mathlib sample. It prints generated JSON only; it does not edit
production artifacts.

`DirectCodecNegative.lean` is an intentional compile-fail probe. It pins the absence of public `ToJson Syntax` and
`FromJson Syntax` instances; `run.sh` requires both failures before testing the source-backed codec. Lean's private
`.olean` serializer is therefore not treated as an application wire API.
