#!/usr/bin/env bash
# Tier 0 — frozen vectors (connection.md §3.9). Runs on every Haskell commit.
# Requires NO Lean: the corpus is read as committed data. This is the PR gate.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
CORPUS="${1:-bisim/corpus}"
[ -d "$CORPUS" ] || { echo "bisim/ci/tier0: corpus directory not found: $CORPUS" >&2; exit 1; }
nix develop path:. -c cabal build all
nix develop path:. -c cabal run -v0 tier0 -- "$CORPUS"
nix develop path:. -c cabal run -v0 tier1 -- "$CORPUS"
