# Exact semantics and workload contract

This note freezes what a lean-fmt result means before the execution strategy is chosen. It is a
semantic contract, not a claim that Lean 4.32 exposes every efficient implementation primitive it
would require.

## Exact source context

For a source snapshot `S`, the exact context consists of all of the following:

1. the exact Lean toolchain and frontend options;
2. the ordered search path, including precedence between roots;
3. Lake's exact per-file `ModuleSetup`, including module/package identity, module-system mode,
   options, plugins, dynamic libraries, import overrides, and ordered import artifacts;
4. the source's ordered header syntax, including `prelude`, import modifiers, and imports;
5. the imported modules and extensions selected by the setup and header; and
6. syntax, macro, command, scoped-environment, and other frontend effects established by earlier
   commands in `S`, in source order.

Changing any component creates a different semantic identity. Import sets are not unordered sets.
An environment containing the union of several files' imports is not exact for any one file merely
because its parser accepts the file. Likewise, the grammar after the final command cannot be used
retroactively for preceding commands.

The differential oracle is a fresh process running Lean's full frontend over the complete source
under this exact context. The process starts with only the target toolchain and target workspace
search path, obtains current per-file setup from `lake setup-file`, and passes it through Lean's
`--setup` input. It does not inherit formatter-project search roots. A candidate fast path is exact
only when its projected result byte-compares with this oracle on ordinary and adversarial sources.

## Analysis and validation levels

The formatter's **syntax analysis** is the command syntax and source mapping produced as the exact
frontend advances in source order. It may avoid elaborating commands irrelevant to formatting only
after differential evidence establishes that the omission cannot change later parsing, syntax
projection, diagnostics, or edits. “Parser-only” and “selective” are implementation descriptions,
not synonyms for exactness.

**Syntax validation** establishes that an edited source can be processed into the intended exact
syntax under the same semantic identity, including the effects needed to parse later commands.
**Elaboration validation** runs the full frontend and requires no new Lean errors. Elaboration is a
strictly stronger, explicitly requested validation level; cache and artifact identities distinguish
the two. Neither level permits trusting a parse performed under broader imports.

The compiler-plugin path is compared against the same oracle. A module linter receives syntax only
after Lean has processed commands in the exact compilation, so it can project formatter data without
serializing the whole syntax tree. Its result is nevertheless usable only when the plugin identity
and compilation trace show that this exact plugin participated.

## Projection and determinism

Source ranges are half-open UTF-8 byte ranges into the snapshotted source. A diagnostic contains a
stable rule code, severity, range, and message. An edit contains its range and replacement text.
Edits are validated against the same source digest that produced them. Overlapping or otherwise
conflicting edits reject the file atomically; no ordering convention is allowed to make a conflict
silently succeed.

Files are reported in bytewise path order. Within a file, diagnostics and edits are ordered by
start byte, end byte, rule code, and stable message/replacement bytes. Infrastructure completion
order, process identifiers, absolute temporary paths, and timings do not enter the semantic report.
Every selected file produces exactly one file result, including syntax or elaboration failures.

## Independent workload axes

Project build state and formatter-result-cache state are separate axes:

- **Ordinary built:** current normal `.olean`/`.ilean` artifacts exist, but no lean-fmt compiler
  artifact is assumed. Reusing only those artifacts is the difficult transparent cold path.
- **Formatter-integrated built:** the exact project compilation included the trusted lean-fmt plugin
  and produced its sidecar. Time spent creating that build is reported separately.
- **Formatter-cache cold:** no valid lean-fmt semantic result entry exists for the selected identity.
- **Formatter-cache warm:** every selected identity has a valid result entry. This does not imply
  that project build artifacts are current unless the cache identity proves the relevant epoch.

Thus “cold” never means “the project needs compiling,” and “built” never means “a formatter result is
cached.” The primary measured paths are ordinary-built/cache-cold, formatter-integrated/cache-cold,
and cache-warm. Any other combination must name both axes rather than borrowing a faster path's label.

## Fixed mathlib workload

- Repository: `/Users/jcreinhold/Code/mathlib4`
- Revision: `783ccda4ee524f13cc5636237be0a1942bc04824`
- Toolchain: `leanprover/lean4:v4.32.0`
- Full selection: all 8,795 `.lean` files below the checkout, excluding `.lake`
- Uniform diagnostic sample: every 137th bytewise-sorted `.lean` path below `Mathlib`, `Archive`,
  and `Counterexamples`; 62 files; SHA-256
  `1936bdb60e01c14fdc986a535ef9317d63775506708e35f4155a9c4c5c6eeeef`

`experiments/select-mathlib-workload.sh` rejects a different revision, toolchain, count, or sample
digest. `experiments/workloads/mathlib-v4.32.0-sample.txt` is the committed sample manifest.

## Resource and evidence contract

Every performance record names the source manifest and digest, project and lean-fmt revisions,
toolchain, machine, build state, cache state, command, wall time, phase times made available by the
command, peak aggregate process-group RSS, memory pressure before/after, swap before/after and delta,
exit status, hard-stop reason, and semantic-output digest.

The profiler terminates the process group at 8,388,608 KiB aggregate RSS or more than 262,144 KiB
new swap. Normal macOS pressure is also an acceptance requirement and is recorded on both sides of
the run. These are operating-envelope failures, not file errors and not reasons to retry above the
envelope.
