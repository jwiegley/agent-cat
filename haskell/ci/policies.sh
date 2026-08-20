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
# And routing (`Agentic.Route`): the backend grammar an operator types — both
# schemes, the first-colon split, the `NAME=BACKEND` split, the refusal wordings
# and the trimming, a blank value being refused where `acp:` is rather than
# becoming an adapter with no name — and the resolution rule itself, which is
# that a question is routed by its model axis and `Nothing` takes the default: a
# pinned question reaches its route, an unrouted pin and every question with no
# axis reach the default. Then the two facts the run's header rests on:
# `routeBackends` is the distinct backends with the default first, so the header
# counts processes and not route lines, and connecting the table with `fmap`
# moves no question, so nothing is answered by a backend the header did not
# name. Then the three claims routing rests on: that it is *invisible to the
# fold* — the flagship run twice, once at an empty route table and once at four
# distinct backends that answer alike, giving byte-identical traces and
# identical bills, which is the whole compatibility argument made executable,
# with each backend noting that it was consulted so that the same rows say where
# the questions went; that it never intercepts a `toolExec`, two commands around
# a pinned ask settling at a table whose default raises and whose one route
# answers; and that a fail-over *crosses* backends, two distinct worlds being
# two backends as far as `routedWorld` is concerned — with, as the acceptance
# criterion, the same two backends abandoning in exactly the old words when no
# spare is declared. Pure throughout: no process, no network, because routing
# reads one field the interpreter has already computed.
#
# No Lean, no corpus; every commit may run it. Thirty checks.
set -euo pipefail
cd "$(dirname "$0")/.."
nix develop path:./. -c cabal run -v0 policy-probe
