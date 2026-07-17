---
kind: state
first_unresolved: 02-integration
---

# Current state

`RFP-SPEC` is verified. The policy is `notes/01-policy.md`; what was run to reach it is
`results/01-policy.md`. Its external prerequisite stack `ruff-03-language-formatting` is verified and
its live implementation was re-read here rather than trusted: every claim below cites the code.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-policy | RFP-SPEC | verified | — |
| 02-integration | RFP-IMPL | planned | RFP-SPEC |
| 03-acceptance | RFP-FINAL | planned | RFP-IMPL |

## What the spec froze

**The command named `format` does not format.** It previews the fixes of selected lint rules and
never consults layout — `tests/check/Layout.lean` holds `namespace     Alpha` and `format` reports it
`clean`, exit 0 (`evidence/01-format-does-not-format.txt`). This is structural, not an oversight:
nothing imports `LeanFmt.Printer` but the test binary; both registry rules are `input := .source`
(`Rules.lean:29,37`), so `RulePlan.requiresSyntax` is `false` (`Config.lean:199-200`) and
`officialArtifacts` is never called (`Application.lean:569`), so **no syntax tree is built at all**;
and `PreparedFile` (`Application.lean:423-427`) has no field to hold one. The printer is compiled
into `LeanFmtCore`, reachable, and starved.

**The stable style surface is empty, by proof rather than deferral.** `Doc.go` reads the margin at
exactly one place — the `.group`/`.brk` case (`Doc.lean:219-229`) — and `LeanFmt/Printer.lean` emits
only `Doc.text`, `Doc.hard`, and `Doc.verbatim`. No `group` means the margin is **never read**, so
every margin produces identical bytes. `line-width` would be a knob that cannot change one, and
`indent-*` the same against `nest`. Line endings are frozen as "preserve", which
`LosslessSource.normalize`/`denormalize` already guarantees. `RFP-IMPL` passes width 100 as an
internal constant.

**Formatter policy is out of semantic cache identity, and holds by construction.** `CacheIdentity`
(`Cache.lean:29-37`) keys findings only (`Semantic.lean:7-12`); style cannot change a finding; the
empty surface keeps `configuration` free of style.

## Blockers and prerequisites

- **`RFP-IMPL` must flip `tests/modes/run.sh`'s `Layout.lean` characterization from exit 0 to exit 1.**
  A green run there after the printer is wired in means the printer is still not reached.
- **Findings cannot be reused across a format.** Canonical text still violates FMT001/FMT002 — the
  printer keeps trailing trivia verbatim (`Printer.lean:208-222`,
  `evidence/02-canonical-text-still-lints.txt`) — and canonicalizing shifts the offsets findings
  index (`Application.lean:420-422`). The composition is forced: format first, then **re-derive**.
- **A cache hit carries no tree.** `Application.lean:557-563` returns from `previewFile` before
  `officialArtifacts` at `:569`. Whether `fix` can take a cache hit at all is open and unmeasured.
- **The first `group` in `Printer.lean` must add `line-width` and its cache-identity component in the
  same commit.** Today's identity is accidentally correct; a `group` makes the margin observable and
  existing entries stale under an identity that never mentioned it — consistent and wrong.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
