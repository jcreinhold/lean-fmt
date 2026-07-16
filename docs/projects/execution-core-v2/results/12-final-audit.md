# ECV2-FINAL requirement audit

Status: verified on 2026-07-16.

The final candidate executable is
`27f7554ed0e0667f520df6341a940ef7ab3efd4e504b89685863221e9b982b7f`.
Detailed commands, measurements, raw-record locators, harness corrections, and audit output are in
[the final evidence](../evidence/12-final-gates.md).

## Completion matrix

| Requirement | Implementation owner | Direct evidence | Conclusion |
| --- | --- | --- | --- |
| Native package/executable named `lean-fmt`; no Rust production | `lakefile.lean`, `Main`, native modules | boundary guard; clean `git archive` build; executable name/digest | achieved |
| Private-by-default module system and no application library API | every active `.lean`, empty `LeanFmt.lean` | module-first scan; exact explicit-public enumeration; clean build | achieved |
| Exact ordered context and no superset semantics | `Project.exactSetup`, `ExactRun`, `Analysis.analyzeExact` | custom/local syntax, malformed header, unresolved import, exact fallback differential suites | achieved |
| Complete deterministic reports | `Project.load`, `Application.execute` | scale selection tests; final 8,795 unique sorted cold/warm reports with identical bytes | achieved |
| Ordinary-built cold driven below ten minutes | ordinary current-module evidence plus source rules | final full cold: 136.549 s, 1,316,240 KiB, normal pressure, no swap growth | achieved |
| Formatter-integrated cold below ten minutes | `RulePlan.requiresSyntax`, conditional `officialArtifacts` | current source-input rules structurally select the same measured ordinary-evidence path; focused facet differential/invalidation suite covers syntax capability | achieved for the current rule surface; no redundant full integrated build |
| Worker-free warm below thirty seconds | `ResultCache.readAll` early return | forced analyzer/artifact/module-evidence failure still completed 8,795 files in 23.012 s | achieved |
| Every full acceptance obeys 8 GiB/pressure/swap envelope | `monitorChild`, `profile-run.sh` | refreshed cold/warm metadata: 1.26/1.10 GiB peaks, pressure 1, swap −8/0 MiB | achieved |
| Preview modes never write; fix is validated/conflict-free/stale-safe | `Edit.Patch`, `Application.previewFile`, `fixFile`, `publishAtomic` | modes suite snapshots bytes/mtime/mode; conflict, validation, staleness, permission, atomic-publication cases | achieved |
| Compiler artifacts are module-owned, traced, atomic, and fail closed | `CompilerPlugin`, `ArtifactStore`, `leanFmtArtifact` Lake facet | compiler suite: custom syntax, config/plugin/source invalidation, corruption, failed elaboration, explicit rebuild | achieved |
| Semantic cache identity is sound and writes atomically | `ResultCache`, source-aware environment epoch | unit/check/scale invalidation matrix; corrupt index miss; dependency-source change with unchanged trace; full atomic index | achieved |
| Editor service reuses one semantic primitive | `Service`, `Application.ExactRun.checkSnapshot` | CLI differential, unsaved source, FIFO/version/error/shutdown/EOF suite; caller inspection | achieved |
| Editor service is bounded and reclaims per request | fresh exact child, per-request input `finally`, capacity-one loop | 100 requests in 44.388 s profile, 1,041,472 KiB peak, normal pressure, zero swap, decreasing parent RSS | achieved |
| Common callers know no cache/setup/worker/resource sequencing | `Main → Cli → Service/Application`; private constructors | declaration/import audit and deep-module manual inspection | achieved |
| No legacy worker protocol, public strategy DTO, lifecycle API, facade, or old production module | active tracked source and boundary guard | positive replacement boundaries plus forbidden-name/source-kind searches | achieved |
| Clean tracked sources are self-contained | Lake package with no external packages | `git archive f3018ce` build, help, check, unit, and service smoke; identical binary digest | achieved |
| Documentation separates ordinary build, formatter integration, cache cold, and cache warm | README, AGENTS, roadmap, results/evidence | vocabulary/claim scan and final measured-number update | achieved |
| All repository and stack gates pass | build, seven behavioral suites, boundary, stack scripts | final sequential sentinels; 12 prompts/no structural errors; generated completion stub checks exactly; diff check | achieved |

## Design conclusion

The replacement is one native Lean application, not a Rust-supervised compiler topology. Its deep
boundaries align with authority: Project owns exact evaluated source identity; compiler/Lake own
successful syntax evidence; ResultCache owns semantic identity and atomic storage; Patch owns a
complete checked transformation; ExactRun owns fresh-child lifecycle and resources; Application owns
the batch transaction; Service owns private stream/version policy; CLI owns presentation and exit
mapping.

The common mathlib path no longer constructs Lean frontend environments at all: current ordinary
module evidence authorizes source-input rules, and the aggregate semantic index handles warm runs.
Exact process-isolated frontend work remains only for genuine misses, edited validation, and unsaved
editor bytes. This removes the 60 GiB failure mode without exposing jobs, pinning, or another resource
strategy, while beating the cold and warm goals by wide margins.
