#!/usr/bin/env bash
# Shim: the performance suite is the compiled `suite-performance` executable now.
# The gate predicates and their negative battery are native (tests/Suites/Performance.lean);
# gates.sh and negative.sh remain until the deletion sweep as the port's provenance.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
lake build lean-fmt lean-fmt-tests suite-performance >&2
exec .lake/build/bin/suite-performance "$@"
