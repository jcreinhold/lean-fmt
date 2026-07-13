#!/usr/bin/env bash
#
# Release smoke test: build the `lean-fmt` binary and worker child, install a worker into a
# throwaway directory, and drive the documented commands (rules / check / diff / fix) over real
# fixtures, asserting the documented exit codes. Nothing here touches the user's real worker
# install — everything is redirected into a temp dir via `LEAN_FMT_WORKERS_DIR` and `--install-dir`.
#
# Requires a Lean toolchain on the PATH (elan) to build the capability; run from a checkout.
#
#   scripts/release-smoke.sh
#
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

toolchain="$(cat lean/lean-toolchain)"
sysroot="$(cd lean && lake env lean --print-prefix)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export LEAN_FMT_WORKERS_DIR="$work/workers"

bin="$repo_root/target/debug/lean-fmt"
child="$repo_root/target/debug/lean-fmt-worker-child"

# Assert that running "$@" exits with the code in $1.
expect_exit() {
  local want="$1"; shift
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: expected exit $want, got $got for: $*" >&2
    exit 1
  fi
  echo "ok (exit $got): $*"
}

echo "==> building lean-fmt + worker child"
cargo build -q -p lean-fmt-cli --bin lean-fmt
cargo build -q -p lean-fmt-worker-child --bin lean-fmt-worker-child

echo "==> version / rules (Lean-free)"
"$bin" --version
"$bin" rules

echo "==> install worker for $toolchain"
"$bin" install-worker --toolchain "$toolchain" --sysroot "$sysroot" \
  --install-dir "$LEAN_FMT_WORKERS_DIR" --worker-child "$child"

echo "==> prepare fixtures"
proj="$work/proj"
mkdir -p "$proj"
printf '%s\n' "$toolchain" > "$proj/lean-toolchain"
printf 'import Init\n\ndef zero : Nat := 0\n' > "$proj/Clean.lean"
printf 'import Init\n\ndef zero : Nat := 0   \n' > "$proj/Messy.lean"   # trailing whitespace

echo "==> check: a clean file is exit 0"
expect_exit 0 "$bin" check --root "$proj" "$proj/Clean.lean"

echo "==> check: a file that needs formatting is exit 1"
expect_exit 1 "$bin" check --root "$proj" "$proj/Messy.lean"

echo "==> diff: pending changes are exit 1 (and print a diff)"
"$bin" diff --root "$proj" "$proj/Messy.lean" || true
expect_exit 1 "$bin" diff --root "$proj" "$proj/Messy.lean"

echo "==> fix: apply, then the file is clean (exit 0 both times)"
expect_exit 0 "$bin" fix --root "$proj" "$proj/Messy.lean"
expect_exit 0 "$bin" check --root "$proj" "$proj/Messy.lean"

if grep -q '   $' "$proj/Messy.lean"; then
  echo "FAIL: trailing whitespace survived fix" >&2
  exit 1
fi

echo "==> release smoke test passed"
