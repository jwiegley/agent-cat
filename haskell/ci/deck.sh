#!/usr/bin/env bash
#
# The transport gate — `Agentic.AgentDeck` against `test/stub-deck.sh`.
#
# No Lean and no live session: every scenario here runs `agentic-run run harden
# --session …` against a fake `agent-deck` this script installs into a
# throwaway directory. What it pins is the part of the runtime the corpus
# cannot reach — the poll loop, the staleness guard, the five named transport
# failures, the re-ask, and the memo table *observed from outside the process*,
# as the gap between the ask nodes a run walked and the messages the session
# was actually sent.
#
#     ./ci/deck.sh
#
# Runs on every commit, beside ci/tier0.sh. Exits 0 only if every scenario
# behaved exactly as written below.
set -uo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d "${TMPDIR:-/tmp}/agentic-deck.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failures=0
scenario=""

note() { echo "ci/deck: $*"; }
bad() { echo "ci/deck: FAIL [$scenario] $*" >&2; failures=$((failures + 1)); }

# Run one scenario: a fresh state directory, a fresh copy of the stub, and the
# run's stdout+stderr and exit code captured for the assertions that follow.
#
# The stub is copied to `$state/bin/agent-deck` and that directory is prepended
# to PATH, so a scenario that passes no `--binary` exercises the same PATH
# lookup a real invocation does.
play() {
  scenario="$1"; shift
  local mode="$1"; shift
  state="$work/$scenario"
  mkdir -p "$state/bin"
  cp test/stub-deck.sh "$state/bin/agent-deck"
  chmod +x "$state/bin/agent-deck"
  out="$state/out"
  DECK_STUB_STATE="$state" DECK_STUB_MODE="$mode" \
    PATH="$state/bin:$PATH" \
    nix develop -c cabal run -v0 agentic-run -- "$@" > "$out" 2>&1
  code=$?
  sends=$( [ -f "$state/sends" ] && cat "$state/sends" || echo 0 )
}

# The assertions. Each prints the scenario, what was expected and what happened,
# because a transport failure that says only "failed" costs an afternoon.
want_code() {
  [ "$code" = "$1" ] || bad "exit $code, wanted $1; output was:$(printf '\n  %s' "$(cat "$out")")"
}
want_sends() {
  [ "$sends" = "$1" ] || bad "the session was sent $sends messages, wanted $1"
}
want_line() {
  grep -qF -- "$1" "$out" || bad "no line containing '$1'; output was:$(printf '\n  %s' "$(cat "$out")")"
}
# The two-pane assertions (scenario 8). A pane's transcript is the witness from
# *outside* the process: the shim gives each session its own state directory, so
# `prompts` is exactly what that pane was sent and nothing else.
saw() {
  grep -qF -- "$2" "$state/$1/prompts" \
    || bad "pane $1 was never sent '$2'"
}
saw_not() {
  grep -qF -- "$2" "$state/$1/prompts" \
    && bad "pane $1 was sent '$2', which belongs to the other pane"
}
# The counts must partition: neither pane idle, and the two summing to the run's
# own bill, so a question cannot have been dropped or sent twice.
want_sends_split() {
  local a b total
  a=$( [ -f "$state/$1/sends" ] && cat "$state/$1/sends" || echo 0 )
  b=$( [ -f "$state/$2/sends" ] && cat "$state/$2/sends" || echo 0 )
  total=$((a + b))
  [ "$a" = "$4" ] || bad "pane $1 was sent $a messages, wanted $4"
  [ "$b" = "$5" ] || bad "pane $2 was sent $b messages, wanted $5"
  [ "$total" = "$3" ] || bad "the two panes were sent $total messages between them, wanted $3"
}

# ---------------------------------------------------------------------------
# 1. The flagship settles.
#
# Seven ask nodes, seven distinct questions, seven messages: the same bills the
# frozen corpus records for example-000 under its own world (billFresh 7,
# billMemo 7), reached here over a transport instead of by the pure fold.
# ---------------------------------------------------------------------------
play happy happy run harden --session stub --poll 20 --timeout 30000
want_code 0
want_line "billFresh   7"
want_line "billMemo    7"
want_sends 7
note "happy: settled in 7 turns, exit 0"

# ---------------------------------------------------------------------------
# 2. The memo table, from outside.
#
# Every reviewer objects and every revision answers with the same patch, so the
# second and third review rounds put questions that were already answered. The
# run walks 13 ask nodes — one of the nine path costs `agentic-run cost harden`
# prints — and sends 6 messages. The gap is the memo table doing its work, and
# it is observable here in a way no pure test can observe it: a question that
# was memoized is a message the session never received.
#
#   round 1  guide, draft, three reviews, one amendment      6 fresh
#   round 2  three reviews and one amendment, all repeats    4 memo hits
#   round 3  three reviews, all repeats                      3 memo hits
#            the amendment budget (2) is spent: unsettled, stop
#
# The two numbers are not this script's invention: they are what the *pure*
# semantics of `Agentic.World` folds for the same world, which is expressible as
# a `WorldSpec` because this stub's every answer is a function of the prompt —
#
#   WorldSpec
#     (TByPrefix [ ("Write out the house style guide", GUIDE)
#                , ("Draft a patch satisfying:",       PATCH) ] PATCH)
#     (VConst (VLitObject ["the buffer bound is still unchecked"]))
#     (FConst True)
#
# — and `trace (toWorld it) (progPlan hardenProgram)` is 13 events long with
# `billFresh 13, billMemo 6`. So the transport run, the scripted run and the
# pure fold agree on the same program at the same world, and `13` is one of the
# nine path costs `agentic-run cost harden` prints. The `happy` scenario above
# is pinned harder still: its 7/7 is what the *frozen corpus* records for
# example-000, and tier1 already holds the pure side against it.
# ---------------------------------------------------------------------------
play objects objects run harden --session stub --binary "$state/bin/agent-deck" --poll 20 --timeout 30000
want_code 0
want_line "billFresh   13"
want_line "billMemo    6"
want_sends 6
note "objects: 13 ask nodes, 6 questions put, exit 0"

# ---------------------------------------------------------------------------
# 3. An answer nobody can read.
#
# The owner says `maybe` to a flag question, twice. `Agentic.Exec` re-asks once
# with the nudge that quotes the reply back, gets the same word, and abandons
# the run rather than recording a consent nobody gave. Five turns settle the
# patch, the sixth and seventh are the two attempts at the flag.
# ---------------------------------------------------------------------------
play undecodable undecodable run harden --session stub --poll 20 --timeout 30000
want_code 3
want_line "no readable flag from person owner after 2 attempts"
want_line "maybe"
want_sends 7
note "undecodable: re-asked once, then abandoned, exit 3"

# ---------------------------------------------------------------------------
# 4. A session that will not answer.
# ---------------------------------------------------------------------------
play stopped stopped run harden --session stub --poll 20 --timeout 30000
want_code 2
want_line "is stopped, so nothing will answer"
note "stopped: named as a transport failure, exit 2"

# ---------------------------------------------------------------------------
# 5. A session that never finishes its turn. The budget is the whole guard
#    against a wedged agent, and it must produce a named error rather than a
#    hang.
# ---------------------------------------------------------------------------
play hang hang run harden --session stub --poll 20 --timeout 1500
want_code 2
want_line "did not answer within 1500ms"
note "hang: bounded by the turn budget, exit 2"

# ---------------------------------------------------------------------------
# 6. The staleness guard.
#
# The stub answers every question but never re-stamps its reply. The first turn
# is fine — there was nothing there before it — but from the second on, the text
# lying in the session is the *previous* turn's, and accepting it would record
# an answer to a question that was never put. The adapter waits instead, and
# times out.
#
# The send count is the sharp assertion here, not the message: an adapter
# *without* the timestamp guard would read the stale text as each question's
# answer, sail through all seven turns and exit 0. Stopping on the second send
# is the guard, and it is the only thing that produces this number. (Which of
# the two `DeckTimedOut` sites fires — the poll loop, or a shell-out that
# outran what was left of the budget — depends on how many polls fit in the
# budget, so the assertion is on the shared wording.)
# ---------------------------------------------------------------------------
play stale stale run harden --session stub --poll 20 --timeout 2000
want_code 2
want_line "did not answer within 2000ms"
want_sends 2
note "stale: the previous turn's text was refused on the second question, exit 2"

# ---------------------------------------------------------------------------
# 7. No such executable.
# ---------------------------------------------------------------------------
play missing happy run harden --session stub --binary "$work/no-such-agent-deck" --poll 20 --timeout 5000
want_code 2
want_line "could not run"
want_sends 0
note "missing: named as a transport failure, exit 2"

# ---------------------------------------------------------------------------
# 8. One program, two panes: the routed pin answered in one and everything else
#    in the other.
#
# THE two-pane scenario, and the deck twin of `ci/acp.sh`'s scenario 13. The
# claim under test is a transport claim — one run, two live deck sessions, each
# question answered in the pane its pin names — so it belongs here, where the
# deck engine, the stub and the seven scenarios above already live. It is also
# the executable half of `run.routes`: the fact carries this run's table to the
# prompts, and what makes the fact worth carrying is that the table is *true*.
#
# The fixture needs one thing the stub was not written for. `test/stub-deck.sh`
# keys `reply`, `seq`, `sends` and `prompts` off `DECK_STUB_STATE` alone and uses
# the session id only as an echoed JSON field, so two `deck:` routes would share
# one reply and answer each other's questions. The stub is *not* edited for this:
# a shim installed as `agent-deck` derives the state directory from the session
# id — which is `$3` in every command the stub implements — and execs it. Two
# instances of one fixture, one per pane, and the seven scenarios above are
# untouched by construction because none of them installs the shim.
#
# `harden` needs no new fixture either: it pins exactly one model (`author served
# by "deep"`) and leaves the three reviewers deliberately unpinned, so the `Just`
# and `Nothing` cases of the resolution rule are both in one program — which is
# why `ci/acp.sh` routes `deep` too.
#
# Under `happy` all three reviewers approve, so the revision settles in its first
# round and the amendment — the second `served by "deep"` — is never put. One
# question is the pin's, six are not, and 1 + 6 is scenario 1's own 7.
# ---------------------------------------------------------------------------
scenario=two-panes
state="$work/$scenario"
mkdir -p "$state/bin"
cp test/stub-deck.sh "$state/stub-deck.sh"
chmod +x "$state/stub-deck.sh"
cat > "$state/bin/agent-deck" <<EOF
#!/bin/sh
# \$3 is the session id in every command this stub implements, so each pane gets
# a state directory — a reply, a stamp, a send count and a transcript — of its
# own, which is the whole of what two panes need that one did not.
DECK_STUB_STATE="$state/\$3" exec "$state/stub-deck.sh" "\$@"
EOF
chmod +x "$state/bin/agent-deck"

out="$state/out"
DECK_STUB_MODE=happy PATH="$state/bin:$PATH" \
  nix develop -c cabal run -v0 agentic-run -- \
    run harden --session pane-a --route 'deep=deck:pane-b' --poll 20 --timeout 30000 \
    > "$out" 2>&1
code=$?

want_code 0
# Routing changes no bill: no field of an `EventKey` names a backend, so the
# numbers are scenario 1's exactly.
want_line "billFresh   7"
want_line "billMemo    7"

# The header, before the first question — and these two lines are `run.routes`'
# two lines, from the same `routeDefault`-then-`routeNamed` walk of the same
# table. `agentic-run`'s own rows declare no run fact, so the fact's text is not
# observable from a transport gate; what is observable is the table it is
# derived from, and `ci/policies.sh` holds `routesFact` at this very table
# against the bytes `(default) = deck:pane-a` / `deep = deck:pane-b`.
want_line "running harden against 2 backends:"
want_line "(default)  agent-deck session pane-a"
grep -qE '^  deep +agent-deck session pane-b$' "$out" \
  || bad "the header did not put deep on its own line with its own pane"

# The first witness: the run's own narration, which names the addressee and the
# code of every consultation it paid for. It says the questions were put; it does
# not say where, because no field of a question names a backend.
want_line "text -> model author: Draft a patch satisfying:"
want_line "text -> tool cat: Write out the house style guide"

# The second, and the one that is the gate: each pane's own transcript. The
# routed pin's question is in the routed pane and in no other, and everything
# with no axis to route by — the tool, the reviewers, the person, the act — is in
# the default's. The two negative pairs are what a run that sent both questions
# to both panes would fail.
saw     pane-b 'question for model author'
saw     pane-b 'model: deep'
saw_not pane-a 'question for model author'
saw_not pane-a 'model: deep'

saw     pane-a 'question for tool cat'
saw     pane-a 'question for model reviewer-correct'
saw     pane-a 'question for person owner'
saw_not pane-b 'question for tool cat'
saw_not pane-b 'question for model reviewer-correct'
saw_not pane-b 'question for person owner'

# Neither pane idle, and the two summing to the run's own bill: 1 for the pin,
# 6 for everything else. The amendment is the second `served by "deep"` and is
# never put, because `happy` settles the revision in its first round.
want_sends_split pane-a pane-b 7 6 1
note "two-panes: one run, two sessions, the pin in its own pane, 6+1 of 7, exit 0"

# ---------------------------------------------------------------------------

scenario=summary
if [ "$failures" = 0 ]; then
  echo "ci/deck: 8 scenarios passed, 0 failed"
else
  echo "ci/deck: $failures scenario assertion(s) failed" >&2
fi
exit $((failures > 0))
