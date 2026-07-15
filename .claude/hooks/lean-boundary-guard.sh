#!/usr/bin/env bash
# Boundary guard (AGENTS.md): lean-fmt links libleanshared in exactly one crate,
# lean-fmt-worker-child (its lone lean-rs-worker-child dependency), and denies unsafe
# workspace-wide with no opt-out crate. This blocks an edit that would breach either
# boundary, surfacing the violation in the edit loop rather than at the CI link/lint step.
set -euo pipefail

payload=$(cat)

f=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')

# The text the edit would introduce (Write -> content, Edit -> new_string,
# MultiEdit -> every edit's new_string).
body=$(printf '%s' "$payload" | jq -r '.tool_input | (.content // .new_string // ([.edits[]?.new_string] | join("\n")) // "")')

case "$f" in
*.rs)
	# unsafe-code is denied workspace-wide with no opt-out crate: an allow(unsafe_code)
	# anywhere reopens it. The extern "C" + lean_ pair should never appear in lean-fmt
	# (it holds no raw FFI); kept as defense-in-depth.
	if printf '%s' "$body" | grep -Eq 'allow\(\s*unsafe_code\s*\)' ||
		{ printf '%s' "$body" | grep -Eq 'extern[[:space:]]+"C"' && printf '%s' "$body" | grep -q 'lean_'; }; then
		echo "lean-fmt boundary (AGENTS.md): unsafe-code is denied workspace-wide with no opt-out crate, and lean-fmt declares no raw Lean FFI. Do not add allow(unsafe_code) or raw lean_* externs; reach Lean only through the lean-fmt-worker-child capability boundary." >&2
		exit 2
	fi
	exit 0
	;;
*Cargo.toml)
	# lean-fmt-worker-child is the one crate allowed to link libleanshared (via its lone
	# lean-rs-worker-child dependency). Every other CRATE manifest must stay Lean-free. The
	# workspace root is the declaration hub — it names the dependency in [workspace.dependencies]
	# so worker-child can reference it with `workspace = true`, which is not itself a link — so
	# only crate manifests under crates/ (excluding worker-child) are subject to the guard.
	case "$f" in
	*/crates/lean-fmt-worker-child/Cargo.toml | crates/lean-fmt-worker-child/Cargo.toml) exit 0 ;;
	*/crates/*/Cargo.toml | crates/*/Cargo.toml) ;;
	*) exit 0 ;;
	esac
	if printf '%s' "$body" | grep -Eq '(^|[^-])lean-rs-worker-child' ||
		printf '%s' "$body" | grep -q 'libleanshared'; then
		echo "lean-fmt boundary (AGENTS.md): only crates/lean-fmt-worker-child may link libleanshared. The lean-fmt application must stay Lean-free and spawn the child as a subprocess." >&2
		exit 2
	fi
	exit 0
	;;
*)
	exit 0
	;;
esac
