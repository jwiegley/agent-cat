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
# And the two laws that were asserted in a haddock and checked by nobody. First,
# `backendSpelling`'s round trip: `parseBackend . backendSpelling == Right` over
# every shape the parser can produce, including the two the trip could plausibly
# lose — an adapter given as a path, and a deck id containing the very colon the
# parser splits on. Second, `run.engine`'s session policy, which is a contract
# between a printed sentence and a predicate: both halves of the fact are built
# from `Agentic.Workflow.sessionPolicy` so that `sharesOneSession` can read them,
# a fresh-per-question run is not sharing, a deck pane is, and a MIXED run is —
# on the strength of its shared half, because a gate that read the other half
# would be reading the one that suits it. That pair lives in different
# repositories from its consumer: `agent-workflows`' `wiggum` refuses to start a
# loop when the predicate holds, and a reworded phrase would switch that gate off
# without failing anything.
#
# And `run.routes`, the fourth run fact, which is the same kind of contract in two
# groups: the SPELLING — the owner's two-pane split asserted verbatim, the default
# labelled `(default)` and printed first, the routes after it in the order they
# were typed, an unrouted live run still carrying the default's line because that
# is the one line that tells it apart from a split, two pins on one pane staying
# two lines because this fact is the mapping and not the roster, and the empty
# text meaning NO TABLE rather than no `--route` — and the READING, which is
# `Agentic.Workflow.routedBackend`: the round trip through `backendSpelling` for
# every route of three tables, the default reachable under its own label, a pin no
# route names falling through to it, a backend containing the very `=` the lines
# are split on surviving, and — the pair a gate exists for — the split putting the
# routed pin somewhere the default is not while its inversion leaves it on the
# default, which is a different run. The consumer is again in another repository,
# and again it is a gate: this is what lets a program say that its evaluator is
# somewhere its workers are not.
#
# And the two prompt quoters (`Agentic.WF`): that `[wft|…|]` and the
# `wfText [wf|…|]` it replaced are the same bytes, hole for hole — the same
# block written both ways, once with no hole and once holing a count and a
# fence, plus three rows on the layout so that two identically broken values
# cannot agree their way past it. That equality is the whole safety argument for
# the sweep that rewrote every define in `Example.Isaac`, and it is a claim
# about two expressions, so it is checked as two expressions rather than
# inferred from a program's numbers.
#
# And the collision policy the fifth verb rests on (`Agentic.Cli.parseCommand`,
# exported for exactly this): a SYNTHETIC registry every one of whose rows is
# named after a verb — `run`, `plan`, `cost`, `list`, `help` — plus one that is
# not. Both shell gates check today's two tables against that reserved set, and
# a green run of either is a fact about those tables that would stay green if
# the parse changed; this is the policy. The verb answers every spelling,
# `run NAME` most of all because it is the verb that could start spending; a row
# named after a verb is reachable through `help NAME` and through nothing else,
# which is what makes unreachable-but-registered a thing a gate can shout about
# rather than a thing to discover; and the row that is NOT a verb keeps both
# answers an ordinary row has, which is the control. Pure: the parse is a
# function of the arguments and the registry's names, and no program in the
# synthetic table is ever run.
#
# The concurrent executor adds six synchronized checks: independent overlap at
# one model with plan-ordered traces; shared-input blocking followed by sibling
# overlap; one in-flight memo owner for equal questions; plan-ordered write
# effects; plan-ordered stateful transport turns; and prompt failure propagation
# that cancels and cleans up a blocked sibling.
#
# No Lean, no corpus; every commit may run it. Forty-three checks, and two
# command lines.
set -euo pipefail
cd "$(dirname "$0")/.."
nix develop path:./. -c cabal run -v0 policy-probe -- +RTS -N8 -RTS
nix develop path:./. -c cabal build agentic-run >/dev/null
agentic_run=$(nix develop path:./. -c cabal list-bin agentic-run)
GHCRTS=-N8 python3 ../test/lineage_probe.py "$agentic_run"
GHCRTS=-N8 python3 ../test/control_probe.py "$agentic_run"

# ---------------------------------------------------------------------------
# The refusals that are the command line's
# ---------------------------------------------------------------------------
#
# The run facts (`Agentic.Workflow.runFacts`) are inputs the RUNNER binds, and
# `--input-arg run.engine=…` is an operator claiming to know what a run did.
# `Agentic.Cli.resolveInputs` refuses it, and the only way to exercise a refusal
# a command line earns is to type the command line: the probe above covers the
# author's half (an `input` under `run.` that is not a fact), which is an
# `error` on a CAF and reachable from Haskell.
#
# `plan` and not `run`, deliberately: the refusal must arrive before anything is
# started, and `plan` starts nothing even when it succeeds — so a green row here
# is evidence about the resolution and not about a transport. Exit 1, because
# nothing ran: it is a usage error, and the way out is another command line.
#
# Two facts and one check, run twice: the refusal's wording is built from
# `runFacts` itself, so the interesting question is not whether it can be worded
# but whether a NEWLY ADDED fact is in the list the resolution reads. `run.routes`
# is the newest, and it is the one whose value an operator is most likely to
# believe is theirs to set — it is a table they typed on the same command line.
refuses_fact() {
  local fact="$1" refusal code
  refusal=$(nix develop path:./. -c cabal run -v0 agentic-run -- \
              plan review-lite --input-arg "$fact=" 2>&1) && code=0 || code=$?

  if [ "$code" != 1 ]; then
    echo "ci/policies: FAIL --input-arg $fact: expected exit 1, actual $code" >&2
    echo "$refusal" >&2
    exit 1
  fi
  case "$refusal" in
    *"is a run fact: the runner binds it"*)
      echo "policy probe: --input-arg $fact is refused, and names who binds it"
      ;;
    *)
      echo "ci/policies: FAIL --input-arg $fact: refused, but not as a run fact" >&2
      echo "$refusal" >&2
      exit 1
      ;;
  esac
}

refuses_fact run.engine
refuses_fact run.routes
