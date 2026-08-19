#!/usr/bin/env bash
# The D6/D7 policy gate (fess wave-1, finding F6): the Exec policies — the
# loud arm, the standing answer, the recovery fork, the retry budgets — each
# probed against the flagship with an unreadable flag, asserting bills, thrown
# wording and logged wording.
#
# And, since fess wave-2's gap V3, the authoring surface's own refusals: the
# mistakes `Agentic.Workflow` answers with an `error` rather than with a type
# error — two functions of one name, a call of a function `defining` was not
# given, and a `named` or a `takes` claiming one of the names the surface
# generates for itself — asserted on the wording, which is all the author sees.
#
# No Lean, no corpus; every commit may run it. Eleven checks.
set -euo pipefail
cd "$(dirname "$0")/.."
nix develop path:./. -c cabal run -v0 policy-probe
