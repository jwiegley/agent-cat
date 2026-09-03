#!/usr/bin/env bash
#
# The routing smoke — the claude adapter and the codex adapter answering
# different parties of ONE program.
#
#     ./ci/route-live.sh
#
# MANUAL ONLY. Never in an automatic lane, and no other gate calls it: it spends
# real money on real accounts. That is the same reason ci/tier1.sh is nightly
# and fails loudly rather than degrading when its prerequisite is absent — a
# gate that quietly does nothing is worse than no gate, and a gate that quietly
# bills somebody is worse than that.
#
# It needs no new program. The flagship is the fixture, for the same reason it
# is ci/acp.sh's: one distinct pin (`model author served by "deep"`), three
# deliberately unpinned model asks, a tool, a person and an act. Codex drafts
# the patch and writes the amendment; Claude reviews it three ways, asks the
# owner, and applies it. One program, two providers, one bill.
#
# Requires `claude-agent-acp` and `codex-acp` reachable (on PATH or at their
# machine-local pins) and both accounts live. Exits 0 only if every assertion
# below held.
#
# WHAT THIS PROVES AND WHAT IT DOES NOT. It proves that two providers answered
# one program under one price and one trace. It does not prove anything about
# how many backends a *configured* route table reaches: a route on a spare fires
# only on a fail-over, so a run with four routes and nothing falling over
# reaches three. Backends *configured* and backends *reached* are different
# numbers, the header states the first and only the trace states the second, and
# any note written from a run of this script must say which one it is quoting.
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

failures=0
scenario=""

note() { echo "ci/route-live: $*"; }
bad() { echo "ci/route-live: FAIL [$scenario] $*" >&2; failures=$((failures + 1)); }

for prog in claude-agent-acp codex-acp; do
  command -v "$prog" > /dev/null || {
    echo "ci/route-live: $prog is not on PATH — this gate needs both real adapters" >&2
    echo "ci/route-live: it is manual on purpose; there is nothing to degrade to" >&2
    exit 1
  }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/agentic-route-live.XXXXXX")"
trap 'rm -rf "$work"' EXIT

play() {
  scenario="$1"; shift
  state="$work/$scenario"
  mkdir -p "$state"
  out="$state/out"
  nix develop path:. -c cabal run -v0 agentic-run -- "$@" --scratch "$state" \
    < /dev/null > "$out" 2>&1
  code=$?
}

want_code() {
  [ "$code" = "$1" ] || bad "exit $code, wanted $1; output was:$(printf '\n  %s' "$(cat "$out")")"
}
want_line() {
  grep -qF -- "$1" "$out" || bad "no line containing '$1'; output was:$(printf '\n  %s' "$(cat "$out")")"
}
want_no_line() {
  grep -qF -- "$1" "$out" && bad "a line contains '$1', and none should"
  return 0
}
# Anchored at both ends, because the numbers are the whole assertion: unanchored,
# `billFresh   7` is a substring of `billFresh   70`, and a run that cost ten
# times what it should would read as the run that cost what it should. The
# trailing ` (` is the report's own (Cli.hs:1062), and it is what ends the number.
bill_of() {
  # The report aligns its columns, so billFresh carries three spaces before
  # the number and billMemo four — match the run of spaces, not a fixed one.
  sed -nE "s/^ +$1 +([0-9]+) \(.*/\1/p" "$out" | head -n1
}

# The flagship ends by asking a *person* whether to apply the patch, and here
# that person is a real one behind a real adapter — and before that question,
# three real reviewers may object and send the author around the revise loop.
# So a live run's bill is not pinnable to any single path: harden's own price
# is `minFold 5, maxFold 15, over 9 paths` (ci/examples.sh pins those numbers
# by equality), and the first live run of this lane landed on 11/11 — a
# reviewer objected, the patch was revised, and the owner then said yes. That
# run was the machinery working, not failing.
#
# What *is* pinnable is the pre-spend contract itself, which is the whole
# thesis: the bills agree with each other, the bill lands inside the priced
# interval, and the trace's act agrees with the person's answer — an applied
# patch leaves an `ack -> tool apply` receipt, a refusal leaves none.
# `owner_said` is left set to `yes`, `no` or `neither` so the note closing the
# scenario can say which branch the person took.
owner_said=""
want_owner_branch() {
  local fresh memo
  fresh="$(bill_of billFresh)"
  memo="$(bill_of billMemo)"
  [ -n "$fresh" ] && [ -n "$memo" ] \
    || bad "no bill lines in the output:$(printf '\n  %s' "$(cat "$out")")"
  [ "$fresh" = "$memo" ] \
    || bad "billFresh $fresh and billMemo $memo disagree, and harden asks no question twice"
  [ "$fresh" -ge 5 ] && [ "$fresh" -le 15 ] \
    || bad "billFresh $fresh is outside harden's own price (minFold 5, maxFold 15) — the pre-spend contract broke"
  if grep -qE '^ +<- yes$' "$out"; then
    owner_said=yes
    grep -qF -- "ack -> tool apply" "$out" \
      || bad "the owner said yes and no apply receipt follows"
  elif grep -qE '^ +<- no$' "$out"; then
    owner_said=no
    grep -qF -- "ack -> tool apply" "$out" \
      && bad "the owner said no and the patch was applied anyway"
  else
    owner_said=neither
    bad "no owner answer (neither 'yes' nor 'no') in the output:$(printf '\n  %s' "$(cat "$out")")"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The smoke: two providers, one program.
#
# The five assertions, in the order they discriminate. The third is the sharp
# one: the flagship's frozen numbers, unchanged on whichever branch the owner
# chose, which is the compatibility argument observed on the real wire rather
# than argued from the type of a `WorldIO`.
#
# The process check runs *during* the run, from a second shell, because the
# thing being pinned is the bracket: two adapters live while the run is, and
# none after it. ci/acp.sh scenario 11 makes the same check at the timeout; here
# it is made at the bracket.
# ---------------------------------------------------------------------------
scenario=two-providers
state="$work/$scenario"
mkdir -p "$state"
out="$state/out"

(
  nix develop path:. -c cabal run -v0 agentic-run -- \
    run harden --engine acp --adapter claude --route 'deep=acp:codex' \
    --scratch "$state" < /dev/null > "$out" 2>&1
  echo $? > "$state/code"
) &
runner=$!

# Give the two adapters time to be spawned, then count them while the run is
# still going. Both names are exact, so a stray adapter of somebody else's is
# not mistaken for one of these.
sleep 20
during_claude=$(pgrep -f claude-agent-acp | wc -l | tr -d ' ')
during_codex=$(pgrep -f codex-acp | wc -l | tr -d ' ')

wait "$runner"
code=$(cat "$state/code")

sleep 2
after_claude=$(pgrep -f claude-agent-acp | wc -l | tr -d ' ')
after_codex=$(pgrep -f codex-acp | wc -l | tr -d ' ')

# 1. The header names two backends, and `deep` is on the codex line.
want_line "running harden against 2 backends:"
want_line "claude-agent-acp"
grep -qE '^  deep +the codex adapter: codex-acp' "$out" \
  || bad "the header does not put deep on the codex line"
want_line "— every unpinned ask, every tool and every person"

# 2. Two adapter processes during the run, and none after it.
[ "$during_claude" -ge 1 ] || bad "no claude-agent-acp was running during the run"
[ "$during_codex" -ge 1 ] || bad "no codex-acp was running during the run"
[ "$after_claude" = 0 ] || bad "$after_claude claude-agent-acp survived the run"
[ "$after_codex" = 0 ] || bad "$after_codex codex-acp survived the run"

# 3. The flagship's frozen numbers, unchanged on the branch the owner chose,
#    and the act agreeing with them — in the one shared directory both
#    providers were pointed at. A route table has no field in any EventKey to
#    move, and this is that claim on the wire.
want_owner_branch

# 4. The consultations name the parties, and the draft is a different voice
#    from the reviews — the one assertion here a single-backend run could not
#    also satisfy. This is `announcingWorld`'s wording (Exec.hs:239): the code,
#    an arrow, the addressee. Its second half is for a human to read; what is
#    asserted is that both were put.
want_line "text -> model author:"
want_line "verdict -> model reviewer-correct:"

# 5. Exit 0.
want_code 0
note "two-providers: codex drafted, claude reviewed, the owner said $owner_said, exit 0"

# ---------------------------------------------------------------------------
# Negative control A: the same command with --route removed is today's run.
#
# Today's header, today's behaviour, today's bills — and the sentence a routed
# run must stop printing, printed, because with one backend it is true.
#
# The owner is as live here as in the routed run and no more pinnable, so the
# bills are read the same either-branch way: what makes this a control is that
# the two runs agree, not that either lands on a number chosen in advance.
# ---------------------------------------------------------------------------
play unrouted run harden --engine acp --adapter claude
want_code 0
want_owner_branch
want_line "running harden against the claude adapter: claude-agent-acp"
want_line "every addressee — model, tool and person — is this one adapter"
want_no_line "backends:"
note "unrouted: today's header, the owner said $owner_said, exit 0"

# ---------------------------------------------------------------------------
# Negative control B: a route naming a party is refused, at exit 1.
#
# `author` is a party and `deep` is what serves it. This is the resolution rule
# defended at the command line, where an operator will actually make the
# mistake — and it costs nothing, because it is refused before an adapter is
# spawned or a token is spent.
# ---------------------------------------------------------------------------
play route-a-party run harden --engine acp --adapter claude --route 'author=acp:codex'
want_code 1
want_line "--route names the model 'author', which this example never pins"
want_no_line "billFresh"
note "route-a-party: refused before anything was spawned, exit 1"

# ---------------------------------------------------------------------------

scenario=summary
if [ "$failures" = 0 ]; then
  echo "ci/route-live: 3 scenarios passed, 0 failed"
  echo "ci/route-live: 2 backends were configured and 2 answered — a route on a"
  echo "ci/route-live: spare would have been configured and not reached."
else
  echo "ci/route-live: $failures scenario assertion(s) failed" >&2
fi
exit $((failures > 0))
