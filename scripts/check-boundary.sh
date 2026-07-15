#!/usr/bin/env bash
# Enforce the process/link boundary independently of editor hooks.
set -euo pipefail
cd "$(dirname "$0")/.."

packages=$(cargo metadata --no-deps --format-version 1 | jq -r '.packages[].name' | sort)
expected=$'lean-fmt\nlean-fmt-worker-child'
if [[ "$packages" != "$expected" ]]; then
	echo "expected exactly lean-fmt and lean-fmt-worker-child packages" >&2
	exit 1
fi

if cargo metadata --no-deps --format-version 1 |
	jq -e '.packages[] | select(.name == "lean-fmt") | .targets[] | select(.kind[] == "lib")' >/dev/null; then
	echo "lean-fmt must not expose a library target" >&2
	exit 1
fi

if rg -n 'lean-rs-worker-child|libleanshared' crates/lean-fmt/Cargo.toml crates/lean-fmt/src; then
	echo "Lean-linking dependencies leaked into the application" >&2
	exit 1
fi

manifest_hits=$(rg -l 'lean-rs-worker-child' crates/*/Cargo.toml | sort)
if [[ "$manifest_hits" != "crates/lean-fmt-worker-child/Cargo.toml" ]]; then
	echo "only the worker-child manifest may name lean-rs-worker-child" >&2
	exit 1
fi

if rg -n 'allow\(unsafe_code\)|extern[[:space:]]+"C"' crates --glob '*.rs'; then
	echo "raw FFI or an unsafe-code opt-out is forbidden" >&2
	exit 1
fi
