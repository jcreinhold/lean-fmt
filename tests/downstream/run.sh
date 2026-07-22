#!/usr/bin/env bash
set -euo pipefail

# Downstream integration. Every other suite exercises the formatter from inside its own workspace,
# where the plugin is reached as `@/LeanFmtCompilerPlugin:shared` and the facet is declared in the
# lakefile that owns the modules. A consuming project has neither. Until this suite existed the
# downstream recipe was a string printed by `compiler setup` and nothing ran it.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
project="$repo_root/tests/downstream/project"
cd "$project"

# The fixture tracks no toolchain of its own: a stale pin would test the wrong compiler.
cp "$repo_root/lean-toolchain" "$project/lean-toolchain"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# 1. The package-level `plugins` entry reaches every module without naming a single `lean_lib`, and
# the cross-package key literal needs guillemets because `lean-fmt` is not a legal Lean identifier.
grep -q 'plugins := #\[`@«lean-fmt»/LeanFmtCompilerPlugin:shared\]' lakefile.lean ||
  fail 'fixture no longer sets the package-level cross-package plugin'
lake build >/dev/null 2>&1 || fail 'downstream project failed to build with the plugin active'

# 2. A module facet declared in the dependency's lakefile registers in the consumer's workspace.
# Lake merges each dependency's facet declarations into one workspace-global map, so this resolves
# even though nothing in the consumer declares it.
rm -f .lake/build/lean-fmt-artifacts/Consumer/Basic.json
lake build +Consumer.Basic:leanFmtArtifact >/dev/null 2>&1 ||
  fail 'the leanFmtArtifact facet did not resolve in the consuming workspace'
[ -s .lake/build/lean-fmt-artifacts/Consumer/Basic.json ] ||
  fail 'facet produced no sidecar for a downstream module'

# 3. The executable resolves across packages: a consumer needs `require` and nothing else to run it.
set +e
check_out=$(lake exe lean-fmt check --root . 2>&1)
check_status=$?
set -e
[ "$check_status" -eq 1 ] ||
  fail "cross-package check returned $check_status; the fixture has findings, so it must be 1"
case "$check_out" in
*"mode=check"*) ;;
*) fail "cross-package check produced no report: $check_out" ;;
esac

# 4. The plugin is an optimization, never an authority. A syntax-tier rule must return the same
# finding whether the fact came from the embedded artifact or the fallback frontend.
# Every command below reports findings by exiting 1, which `set -e` with `pipefail` would treat as a
# script failure. Findings are the expected result here, so status is checked explicitly instead.
set +e
served=$(lake exe lean-fmt check --root . --preview --select FMT010 Consumer/Syntax.lean 2>&1 | head -1)
fallback=$(LEAN_FMT_DISABLE_ARTIFACT=1 lake exe lean-fmt check --root . --preview --select FMT010 \
  Consumer/Syntax.lean 2>&1 | head -1)
set -e
[ "$served" = "$fallback" ] ||
  fail "artifact and frontend disagree downstream: '$served' vs '$fallback'"
case "$served" in
*FMT010*) ;;
*) fail "syntax-tier rule did not fire downstream: $served" ;;
esac

# 5. `lake lint` drives the formatter through Lake's own lint-driver protocol, which is what
# `leanprover/lean-action` probes with `check-lint` before running it in CI. Both halves of the
# driver spec need guillemets: the package name and the executable name.
grep -q 'lintDriver := "«lean-fmt»/«lean-fmt»"' lakefile.lean ||
  fail 'fixture no longer configures the lint driver'
lake check-lint >/dev/null 2>&1 || fail 'lake check-lint does not see a configured driver'
set +e
lake lint >/tmp/lean-fmt-downstream-lint.txt 2>&1
lint_status=$?
set -e
[ "$lint_status" -eq 1 ] ||
  fail "lake lint returned $lint_status; the fixture has a finding, so the driver must exit 1"
grep -q 'FMT003 duplicate import' /tmp/lean-fmt-downstream-lint.txt ||
  fail 'lake lint did not carry the driver output through'

# 6. Regression: a silent message is a carrier, not a diagnostic. The plugin writes the artifact into
# the persistent lint log, so an integrated project's frontend run sees it beside real errors. Before
# `Analysis.messageStrings` filtered `isSilent`, a broken file printed the whole serialized projection
# as its diagnostic. It needs a plugin-enabled project *and* a file that elaborates far enough for the
# module linter to run, which is why no in-repo broken fixture reached it.
set +e
broken=$(lake exe lean-fmt check --root . Standalone/Broken.lean 2>&1)
set -e
case "$broken" in
*lean-fmt.module-artifact*) fail 'the module artifact leaked into a broken-source diagnostic' ;;
esac
case "$broken" in
*"Unknown identifier"*) ;;
*) fail "the real error stopped being reported: $broken" ;;
esac

printf 'downstream integration ok\n'
