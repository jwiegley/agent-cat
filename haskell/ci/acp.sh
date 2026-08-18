#!/usr/bin/env bash
#
# The ACP gate — `Agentic.Acp` against `agent-cat/test/stub_adapter.py`.
#
# No Lean, no network and no real adapter: every scenario here runs
# `agentic-run run … --engine acp` against the deterministic double the Lean
# runtime is tested with, which speaks real ACP over real pipes — the same
# response shapes, the same 39 KB single line, the same integer-id permission
# request — and answers the flagship's questions from a table keyed on the
# prompt.
#
#     ./ci/acp.sh
#
# What it pins is the part of the runtime the corpus cannot reach: the
# handshake, the session-per-question policy, the permission decision *per
# question*, the stop reason (which is the thing this transport can promise and
# `ci/deck.sh`'s cannot), and the five named transport failures.
#
# Runs on every commit, beside ci/deck.sh. Exits 0 only if every scenario
# behaved exactly as written below.
set -uo pipefail
cd "$(dirname "$0")/.."

stub="../test/stub_adapter.py"
[ -f "$stub" ] || { echo "ci/acp: no $stub — this gate needs agent-cat's stub adapter" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/agentic-acp.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failures=0
scenario=""

note() { echo "ci/acp: $*"; }
bad() { echo "ci/acp: FAIL [$scenario] $*" >&2; failures=$((failures + 1)); }

# Run one scenario in a directory of its own, which is also the adapter's
# working directory: `permissionByCode` authorizes a tool call *there*, so what
# a run wrote — and what it did not — is a fact about `$state` and nothing else.
#
# stdin is /dev/null on purpose. Every addressee, the `person owner` included,
# is put to the adapter, and the stub answers for the person (`--adapter-arg
# --refuse` is how it is told to say no) — exactly as agent-cat's own CLI
# arranges it against the stub, where `askPersonOnStdin := !stubbed`. Nothing
# reads a keyboard here, and /dev/null is what makes that a fact rather than a
# hope.
play() {
  scenario="$1"; shift
  state="$work/$scenario"
  mkdir -p "$state"
  out="$state/out"
  nix develop path:./. -c cabal run -v0 agentic-run -- "$@" --scratch "$state" \
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
# The bills, which are the run's own report of what it walked and what it put.
want_bills() {
  want_line "billFresh   $1"
  want_line "billMemo    $2"
}
want_file() {
  [ -f "$state/$1" ] || bad "$1 was not written; the directory holds: $(ls "$state" | tr '\n' ' ')"
}
want_no_file() {
  [ -f "$state/$1" ] && bad "$1 was written, and nothing should have written it"
  return 0
}

# ---------------------------------------------------------------------------
# 1. The flagship settles, and the act acts.
#
# Seven ask nodes, seven distinct questions, seven prompts: the same bills the
# frozen corpus records for example-000 (billFresh 7, billMemo 7), reached over
# a real protocol instead of by the pure fold. `demo/Main.lean`'s
# `expectedApply` is the same 7, and it is `Dsl.bill_flagship_apply` restated.
#
# `applied.c` is the sharp assertion, not the bill: `Decode .ack` is total, so a
# receipt proves only that something replied. The stub's `Apply:` turn asks
# permission, is granted it because the question is an act, and writes the lines
# the patch adds — so the file is the evidence that the act happened, and its
# contents are the evidence that it was *this* patch.
# ---------------------------------------------------------------------------
play happy run harden --engine acp --adapter stub --timeout 60000
want_code 0
want_bills 7 7
want_line "permission granted to 'apply the patch' during the ack question put to tool apply"
want_file applied.c
grep -qF 'snprintf(buf, sizeof buf' "$state/applied.c" \
  || bad "applied.c does not hold the line the patch adds"
note "happy: settled in 7 turns, the act wrote applied.c, exit 0"

# ---------------------------------------------------------------------------
# 2. The owner refuses.
#
# `--refuse` makes the stub answer *no* to the consent question, which is
# `Harden.no_ack_of_refused`'s hypothesis made of bytes. The apply question is
# then never put: six consultations instead of seven — `Harden.bill_refuse_demo`,
# `demo/Main.lean`'s `expectedRefuse` — and nothing is written, because no act
# ran to write it.
# ---------------------------------------------------------------------------
play refuse run harden --engine acp --adapter stub --adapter-arg --refuse --timeout 60000
want_code 0
want_bills 6 6
want_no_file applied.c
note "refuse: 6 consultations and no act, exit 0"

# ---------------------------------------------------------------------------
# 3. The smallest program.
#
# `hello` asks two questions and acts once, and the stub has no canned answer
# for any of them — it says so, in prose, and the run reads that prose as the
# text and the receipt it asked for. Three consultations, no branch, exit 0: a
# program whose price the analysis knows exactly, paid exactly.
# ---------------------------------------------------------------------------
play hello run hello --engine acp --adapter stub --timeout 60000
want_code 0
want_bills 3 3
note "hello: 3 consultations, exit 0"

# ---------------------------------------------------------------------------
# 4. An agent that edits the workspace while it is only being asked a question.
#
# `--write-on-ask` is the measured defect of a real run in its smallest form:
# during the AUTHOR's *draft* turn the adapter asks permission to rewrite
# `parse.c`. A client holding one connection-wide `grant` allows it, and the
# workspace changes during a turn that asked for nothing but words.
#
# `Exec.permissionByCode` decides per question instead, so every ask is DENIED
# and only the act is granted. The run still bills 7/7 — the denial costs
# nothing, because the stub answers anyway — and the two file assertions are the
# whole point: `applied.c` exists (the act ran) and `parse.c` does not (no ask
# wrote).
# ---------------------------------------------------------------------------
play write-on-ask run harden --engine acp --adapter stub --adapter-arg --write-on-ask --timeout 60000
want_code 0
want_bills 7 7
want_line "permission DENIED  to 'edit parse.c while answering' during the text question put to model author"
want_line "permission granted to 'apply the patch' during the ack question put to tool apply"
want_file applied.c
want_no_file parse.c
note "write-on-ask: every ask denied, the act granted, exit 0"

# ---------------------------------------------------------------------------
# 5. An act whose turn did not finish. THE scenario this transport exists for.
#
# `--cancel=Apply:` makes the apply turn stream its `DONE` and then answer
# `{"stopReason":"cancelled"}`. The bytes are readable — `Decode .ack` is total
# and would accept anything at all — so nothing downstream could tell this cell
# from one an act really produced. `Exec.requiresCompletedTurn` says an `ack`
# needs a completed turn, and the run is abandoned instead, quoting the stop
# reason, the addressee and the words.
#
# `ci/deck.sh` has no scenario like this and cannot: the agent-deck CLI reports
# no stop reason, so that transport cannot tell a finished act from an
# interrupted one. This is the difference between the two engines, made
# executable.
# ---------------------------------------------------------------------------
play cancelled-act run harden --engine acp --adapter stub --adapter-arg --cancel=Apply: --timeout 60000
want_code 3
want_line "ended 'cancelled' rather than completing"
want_line "an unfinished turn did not perform the act it was asked to perform"
note "cancelled-act: the receipt was refused, exit 3"

# ---------------------------------------------------------------------------
# 6. …and an ask whose turn did not finish is still an answer.
#
# The other half of the same rule, and the reason it is a rule and not a panic:
# a review that was cut off mid-sentence is still a review, so a cancelled
# `verdict` from a model is warned about and recorded. The run settles, bills
# 7/7 and exits 0 — refusal is an answer, and so is an interrupted opinion.
# ---------------------------------------------------------------------------
play cancelled-ask run harden --engine acp --adapter stub --adapter-arg '--cancel=correct?' --timeout 60000
want_code 0
want_bills 7 7
want_line "turn for a verdict from model reviewer-correct ended 'cancelled', not 'end_turn'"
note "cancelled-ask: warned, recorded and settled, exit 0"

# ---------------------------------------------------------------------------
# 7. A command line that named no adapter.
#
# The default is the stub — agent-cat's own (`cli/AgentCat.lean`'s
# `Options.adapter`) — and it is *announced*, because `stub` is both a word an
# operator can type and what a silent command line means, and a run that reached
# a real agent by default would spend somebody's tokens without saying so.
# ---------------------------------------------------------------------------
play default-adapter run harden --engine acp --timeout 60000
want_code 0
want_bills 7 7
want_line "no --adapter given, so the stub answers"
note "default-adapter: the default is the stub, and it says so, exit 0"

# ---------------------------------------------------------------------------
# 8. An adapter that dies at once.
#
# `/usr/bin/false` starts and exits, so the pipe reaches EOF with the handshake
# outstanding. The failure must name the program and the call that was waiting,
# because "the adapter is not what you think it is" and "the adapter is slow"
# ask different things of the operator.
# ---------------------------------------------------------------------------
play dead run harden --engine acp --adapter /usr/bin/false --timeout 10000
want_code 2
want_line "closed its output while the initialize handshake was outstanding"
note "dead: named as a transport failure, exit 2"

# ---------------------------------------------------------------------------
# 9. An adapter that is not there at all.
# ---------------------------------------------------------------------------
play missing run harden --engine acp --adapter "$work/no-such-adapter" --timeout 10000
want_code 2
want_line "no adapter"
note "missing: named as a transport failure, exit 2"

# ---------------------------------------------------------------------------
# 10. An adapter that talks, but not in JSON-RPC.
#
# The line is quoted back verbatim: a client that read on hoping for something
# parseable would report the timeout of a conversation that was never one.
# ---------------------------------------------------------------------------
play babble run harden --engine acp --adapter test/acp-misbehave.sh --adapter-arg babble --timeout 10000
want_code 2
want_line "said a line this client could not read"
want_line "I am not a JSON-RPC adapter, I am prose."
note "babble: the unparseable line is quoted, exit 2"

# ---------------------------------------------------------------------------
# 11. An adapter that never answers.
#
# The turn budget is the whole guard against a wedged adapter, and it must
# produce a named failure that says which question was outstanding — and leave
# no child behind, which is the second assertion: the helper `exec`s a sleep of
# an unusual length, so a survivor is identifiable as this scenario's.
# ---------------------------------------------------------------------------
play mute run harden --engine acp --adapter test/acp-misbehave.sh --adapter-arg mute --timeout 3000
want_code 2
want_line "did not answer the initialize handshake within 3000ms"
want_line "it was killed"
sleep 1
pgrep -f "sleep 37" > /dev/null && bad "the wedged adapter was left running"
note "mute: bounded by the turn budget and killed, exit 2"

# ---------------------------------------------------------------------------
# 12. A flag that means nothing to the engine it was given to.
#
# `--adapter` names a child this run starts and the deck engine starts none;
# `--binary` is the deck's executable and the acp engine has no use for one.
# Both are usage errors — exit 1, before anything is spawned — because a flag
# silently accepted by the transport it means nothing to is a run configured by
# a line nobody read.
# ---------------------------------------------------------------------------
play crossed-flags run harden --session some-session --adapter claude
want_code 1
want_line "--adapter is not the deck engine's to take"
want_no_line "billFresh"
note "crossed-flags: refused before anything was spawned, exit 1"

# ---------------------------------------------------------------------------

scenario=summary
if [ "$failures" = 0 ]; then
  echo "ci/acp: 12 scenarios passed, 0 failed"
else
  echo "ci/acp: $failures scenario assertion(s) failed" >&2
fi
exit $((failures > 0))
