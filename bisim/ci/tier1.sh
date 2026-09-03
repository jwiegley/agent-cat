#!/usr/bin/env bash
# Tier 1 — live differential (connection.md §3.9). Nightly, and on any change
# to Agentic/Core/** or this repo's semantic core. Needs the Lean oracle as a
# PREBUILT binary — never `lake build` inside a test run (the one-build rule,
# D6). Fails loudly when the binary is missing rather than degrading to
# Tier 0: a green suite that quietly tested nothing is the failure mode the
# whole conformance program exists to avoid.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
ORACLE="${ORACLE:-bisim/.lake/build/bin/conformance-oracle}"
N="${N:-500}"
[ -x "$ORACLE" ] || { echo "bisim/ci/tier1: oracle binary not found; Tier 1 skipped is NOT green: $ORACLE" >&2; exit 1; }
nix develop path:. -c cabal build all
nix develop path:. -c cabal run -v0 exe:bisim -- --oracle "$ORACLE" --n "$N" ${SEED:+--seed "$SEED"}
