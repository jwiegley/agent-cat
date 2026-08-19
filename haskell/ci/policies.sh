#!/usr/bin/env bash
# The D6/D7 policy gate (fess wave-1, finding F6): the Exec policies — the
# loud arm, the standing answer, the recovery fork, the retry budgets — each
# probed against the flagship with an unreadable flag, asserting bills, thrown
# wording and logged wording. No Lean, no corpus; every commit may run it.
set -euo pipefail
cd "$(dirname "$0")/.."
nix develop path:./. -c cabal run -v0 policy-probe
