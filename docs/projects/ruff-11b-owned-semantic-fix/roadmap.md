---
kind: roadmap
topic: "Owned, fixable deprecation rule and the info-tree capability split"
main_results: [ROS-FINAL]
prereq_stacks: [ruff-06-fix-safety, ruff-10b-syntax-fix-composition, ruff-11-semantic-rules]
blueprint_tracked: false
---

# Owned, fixable deprecation rule and the info-tree capability split

## Goal

Ship the **owned, fixable FMT014** — a validated *unsafe* autofix that rewrites a bare-identifier
occurrence of a deprecated declaration to its replacement name — and the **info-tree capability split**
that lets its whole-file info-tree walk be paid only when that fix is demanded, keeping the semantic
tier a sound cache gate. Today FMT014 is *surfaced* and report-only (`fixable:false`,
`LeanFmt/Rules.lean`): it re-emits the compiler's own deprecation diagnostic and offers no fix. The
substrate for the fix — `deprecatedAttr.getParam?` returning `{newName?, since?, text?}` from
`Environment` data, the info-tree occurrence resolution (`TermInfo`/`addConstInfo`), and the Design-B
capability model — is fully characterized and frozen in `ruff-11`'s RMR-SPEC and explicitly deferred
there. This stack holds exactly that deferral: the owned occurrence fact, the capability-gated capture,
and the applied rename, wired behind the private `Application` boundary and driven by the real FMT014
rule.

## Origin

`ruff-11`'s RMR-SPEC (`ruff-11-semantic-rules/notes/01-authority.md` §§6,8, verified) froze two coupled,
deferred pieces and named no owning stack:

- **§8 — the owned/fixable FMT014 autofix.** A report-only FMT014 ships in RMR-IMPL; its structured
  *unsafe* fix (replace the occurrence text with the deprecation's `newName?`) is deferred behind the
  info-tree-capture pitfall. The projection would carry, per deprecated occurrence,
  `(range, declName, newName?, since?, text?)`; the rule emits an `unsafe` fix for a **bare-identifier**
  occurrence only — a textual name swap does not preserve dot-notation, argument structure, or `open`
  context, so it is never `safe`.
- **§6 — Design B, the capability split.** The monolithic Design A (both semantic sub-facts captured
  together) stays a sound tier gate only while every sub-fact is cheap. The owned occurrence fact needs
  the whole-file info trees, which `waitForFinalCmdState?` (what `analyzeExact` reads today) does not
  hold — info state is reset per command (`Command.lean:642-643`), so that snapshot carries only the
  *final* command's trees; the whole-file trees live in the incremental snapshot tree
  (`Frontend.lean:118-122,357-358`). Forcing that walk onto every `format` run is the cost Design B
  exists to prevent. RMR-SPEC §6 froze the split — `SemanticCaps`, `Option` sub-fields, `SemanticResult`
  `v6 → v7`, `cacheHitServes` requiring `demandedCaps ⊆ entry caps` — as "required later, when §8 lands."

RMR-SPEC said the two "land together, after the surfaced first cut is proven"; RMR-IMPL/RMR-FINAL shipped
and accepted the four surfaced rules, and RMR-FINAL's remaining-uncertainty records this as "the next
stack's work, not a gap in this one." This is that stack — the semantic analog of `ruff-10b`, which held
the `fix`-composition wiring `ruff-06` specified and deferred until a real rule could drive it.

## Completion contract

- `fix --select FMT014` with the fix **admitted** (unsafe → `--unsafe` or an extend-unsafe override,
  `ruff-06`'s applicability model) rewrites a bare-identifier occurrence of a deprecated declaration to
  its `newName?`, atomically, validated by the existing output re-elaboration validator; the written
  file re-`check`s clean. Without admission the fix is *withheld*, reported but never applied.
- The fix applies **only** to a bare-identifier occurrence whose resolved constant is the deprecated
  declaration and whose entry carries a `newName?`. Dot-notation, applied-receiver, and `open`-shadowed
  occurrences, and entries with `newName? = none`, stay report-only — the surfaced FMT014 finding is
  unchanged for them.
- The owned occurrence fact is captured from the **whole-file info trees**, never from
  `waitForFinalCmdState?`, and is paid **only** when a run demands the fixable capability. A plain
  `format`/`check`, and a surfaced-only FMT014 selection (report, no fix admission), never trigger the
  info-tree walk.
- Capability-tracked `.semantic`: `cacheHitServes` serves an entry only when `demandedCaps ⊆ entry caps`,
  and `Tier.satisfies` stays sound. A monolithic-era entry (notations + diagnostics, no occurrence cap)
  **misses** a fixable-FMT014 demand rather than serving a false clean.
- The surfaced FMT014 report, the source/syntax/semantic fast paths, and the invariant that `check`,
  `format`, and `diff` never write source are all preserved. The artifact and `SemanticResult` identity
  include the compiler/runtime version and the captured capabilities.
- Exact ordered imports, search-path precedence, file-local syntax effects, validation identity, private
  application boundaries, and atomic writes are preserved. Rules gain no parser or lifecycle authority;
  no `Environment`, `InfoTree`, `Position`, or `FileMap` crosses into a rule — only immutable data.

## Work order

1. **ROS-SPEC — Freeze the owned-occurrence projection and the capability split.** Characterize
   first-hand the whole-file info-tree pitfall (that `waitForFinalCmdState?` holds only the final
   command's trees, and where the whole-file trees are reachable — via the snapshot tree
   `analyzeExact` already walks for diagnostics, or the incremental tree `Frontend.lean:118-122,357-358`)
   and the `TermInfo`/`addConstInfo` occurrence resolution (`InfoTree/Main.lean:344-353` —
   `ti.expr.isConst → constName`, `ti.stx.getRange?`). Freeze: (a) the per-occurrence owned fact
   `(range, declName, newName?, since?, text?)` and the **bare-identifier fixable predicate** (what
   distinguishes an occurrence a textual rename preserves from one it does not); (b) the capability
   model — `SemanticCaps` shape, `Option` sub-fields (none = not captured vs some = captured-possibly-
   empty), `SemanticResult v6 → v7`, `cacheHitServes` `demandedCaps ⊆ caps`, and the argument that
   `Tier.satisfies` stays a sound gate; (c) the `unsafe` classification and the `ruff-06` applicability/
   conflict/transaction/validator path the applied rename rides. Design the capability interface twice —
   a sub-tier of `.semantic` vs an orthogonal caps axis beside the tier — and compare caller knowledge,
   invariants hidden, error surface, exactness, cache identity, critical path, and memory
   enforceability. Name the demand trigger, the soundness argument, and the adversarial cases ROS-FINAL
   must drive.
2. **ROS-IMPL — Capture whole-file info trees, ship the fixable FMT014 and the capability gate.**
   Implement the smallest deep capability: capture the whole-file info trees under demand, project the
   owned occurrences (immutable data only), gate the walk on the fixable capability, ship FMT014's
   `unsafe` fix through `ruff-06`'s applicability/conflict/transaction/validator machinery, bump the
   artifact and `SemanticResult` schemas, and extend `cacheHitServes` to require `demandedCaps ⊆ caps`.
   Keep the surfaced FMT014 report and every source/syntax/semantic fast path; remove the deferral path
   rather than leaving a parallel one. Add or update persistent regression tests at the owning layer and
   a fresh-frontend differential that the projected occurrence `(range, declName, newName?)` matches
   Lean's own resolution.
3. **ROS-FINAL — Adversarial acceptance and the info-tree cost.** Drive the cases §8 implies: the rename
   applies and re-elaborates clean; unsafe gating (never applied without admission, withheld and
   reported otherwise); the fixable predicate (dot-notation, applied-receiver, `open`-shadowed
   occurrences, and `newName? = none` entries stay report-only with no fix); idempotence (a second `fix`
   is a no-op and re-`check` is clean); capability demand-gating **both directions** (the info-tree walk
   is absent from a plain `format` and a surfaced-only FMT014 selection, and present only under the
   fixable demand — the cost Design B exists to bound, measured on a named stress file); a
   monolithic-era cache entry missing a fixable demand rather than a false clean; pass-order
   independence; and a frozen-sample read-only review of any real deprecation rename. Manually review
   every applied rename for exactness.

## Evidence and verification

Every prompt writes a `results/<stem>.md` note with commands, raw measurements or evidence locators,
changed design decisions, files changed, checks read, and remaining uncertainty. Use focused fixtures,
the frozen representative mathlib sample, and named stress files. Do not run complete mathlib in this
stack.

Run the affected Lean build/tests (`LEAN_NUM_THREADS=1 lake build`, `lake exe lean-fmt-tests`) and the
touched integration suites (`tests/semantic/run.sh`, `tests/modes/run.sh`, `tests/check/run.sh`,
`tests/boundary/run.sh`, and any suite named by a touched module), this stack's structural checker,
`write_next.py --check`, and `git diff --check`. A performance record for the info-tree capture names
workload, profile, cache/build state, machine/toolchain/commit, wall time, peak aggregate RSS, memory
pressure, and swap delta, and shows the walk is absent from runs that did not demand it.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- A textual rename that does not preserve meaning — dot-notation, applied receiver, `open`-shadowing,
  or a macro-scoped occurrence — must never be applied. The fix is `unsafe`, bare-identifier only, and
  validated by output re-elaboration; stop rather than shipping a rename a byte- or occurrence-level
  argument cannot justify.
- The whole-file info-tree walk must never be forced onto a run that did not demand the fixable
  capability; that gating is the whole reason for the capability split.
- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation
  identity, private application boundaries, and atomic writes. `check`/`format`/`diff` never write.
  The artifact and result-cache identity include the compiler/runtime version and the captured
  capabilities.
- No retained mutable environment; the owned occurrence fact is immutable data, and no `Environment`,
  `InfoTree`, `Position`, or `FileMap` crosses into a rule.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap. Do not run
  complete mathlib in this stack.
- Prefer pure Lean; another language requires a named unavailable Lean capability and a measured
  benefit. Do not restore workers, public strategy controls, accumulated/superset parsing, or per-file
  Lake runs. Do not give rules parser or application-lifecycle authority. `LeanFmt.Rules` stays out of
  the compiler-plugin closure and its library globs.
