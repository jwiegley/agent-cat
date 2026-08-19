#!/usr/bin/env bash
# The D6/D7 policy gate (fess wave-1, finding F6): the Exec policies — the
# loud arm, the standing answer, the recovery fork, the retry budgets — each
# probed against the flagship with an unreadable flag, asserting bills, thrown
# wording and logged wording.
#
# And, since wave three, fail-over itself (D6): a question pinned `deep or
# broad`, a world that raises a gap at `deep` and answers at `broad`, and four
# assertions — the run settles on the spare, the trace names the model that
# actually answered, the fall-back is narrated on the way, and, with no chain
# declared, the very same world and program abandon in exactly the words they
# always did. The probe that used to assert `FailOver`'s refusal now asserts
# what a fail-over with nowhere to go does instead, which is abandon.
#
# And, since fess wave-2's gap V3, the authoring surface's own refusals: the
# mistakes `Agentic.Workflow` answers with an `error` rather than with a type
# error — two functions of one name, a call of a function `defining` was not
# given, and a `named` or a `takes` claiming one of the names the surface
# generates for itself — asserted on the wording, which is all the author sees.
#
# And D5's executing world: a `toolExec` act whose command exits 0 answers yes
# and pays for the act, one that exits nonzero answers no and does not, two
# commands at one tool id are two questions (billMemo 2 — the reason the argv
# rides in the addressee), and a command that cannot be run is a named gap
# rather than an answer. `true` and `false` and nothing else; the whole program
# is `toolExec`, so a question reaching the world beneath is a raised error.
#
# No Lean, no corpus; every commit may run it. Nineteen checks.
set -euo pipefail
cd "$(dirname "$0")/.."
nix develop path:./. -c cabal run -v0 policy-probe
