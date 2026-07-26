#!/usr/bin/env bash
# Shim: the native-layout suite is the compiled `suite-native-layout` executable now.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt suite-native-layout >&2
exec .lake/build/bin/suite-native-layout "$@"
