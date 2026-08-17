#!/usr/bin/env bash
# Tier 1 — live differential (connection.md §3.9). Nightly, and on any change
# to Agentic/Core/** or this repo's semantic core. Needs the Lean oracle as a
# PREBUILT binary — never `lake build` inside a test run (the one-build rule,
# D6). Fails loudly when the binary is missing rather than degrading to
# Tier 0: a green suite that quietly tested nothing is the failure mode the
# whole conformance program exists to avoid.
set -euo pipefail
cd "$(dirname "$0")/.."
ORACLE="${ORACLE:-../.lake/build/bin/conformance-oracle}"
N="${N:-500}"
[ -x "$ORACLE" ] || { echo "ci/tier1: oracle binary not found; Tier 1 skipped is NOT green: $ORACLE" >&2; exit 1; }
nix develop -c cabal build all
nix develop -c cabal run -v0 bisim -- --oracle "$ORACLE" --n "$N" ${SEED:+--seed "$SEED"}
