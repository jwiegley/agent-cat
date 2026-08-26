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
# And, since routing, the part of it that reaches *two* adapters: one program,
# two stub processes, each question dispatched by the serving model its
# `served by` pin names (13); eager startup, so a dead route costs nothing (14);
# and the usage refusals that keep a route from being silently inert (15). Two
# stubs and never a real agent, here as everywhere in this gate — the two
# backends are told apart by *outcome*, not by a flag.
#
# And, since acat-owa, the part of it that decides *whose voice* a turn was in:
# an adapter that writes the measured model-fallback banner into the answer
# stream, and a client that separates it from the answer, announces the
# separation, and puts a clean answer into every prompt that quotes it (16).
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
# working directory: `permissionByIntent` authorizes an effect tool call there,
# so what a run wrote — and did not — is local to `$state`.
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
# a real protocol instead of by the pure fold. The same 7 is what the kernel
# proves of the flagship's apply path (Agentic/Core/DslFlagship.lean).
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
# then never put: six consultations instead of seven — `Harden.bill_refuse_demo`
# (Agentic/Core/HardenPatch.lean:967) — and nothing is written, because no act
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
# `Exec.permissionByIntent` grants only semantic effects, so this consultation is
# denied while the final act is granted. The run still bills 7/7 — denial costs
# nothing because the stub answers anyway. File assertions pin both outcomes.
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
# The default is the stub — the deterministic double, the same default the
# retired Lean CLI kept — and it is *announced*, because `stub` is both a word an
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
# 13. Two adapters in one run, and each question went to the right one.
#
# THE routing scenario, and it needs no new fixture: the flagship already
# contains one distinct pin (`model author served by "deep"`), three
# *deliberately unpinned* model asks (the three reviewers, so the lenses stay
# comparable), a tool, a person and an act — the `Just` case and the `Nothing`
# case of the resolution rule in one program, with the tool question asked
# *before* the routed one so that ordering is observable.
#
# The two backends are both stubs, distinguished by *outcome* rather than by a
# flag. `deep` is routed to a two-line wrapper script that runs the same stub
# under `--write-on-ask` — which is scenario 4's measured defect: the adapter
# asks permission to rewrite `parse.c` during a turn that was only asked a
# consultation, and `permissionByIntent` denies it. The routed stub therefore
# identifies itself by denial on exactly the requests it answered.
#
# That the wrapper suffices is the whole of the argument against a `--route-arg`
# flag: `adapterArgv` falls through to a bare path for any word it does not
# know, so a per-route adapter argument is a shell script and a flag is forever.
#
# The pair of want_line/want_no_line assertions is the resolution rule proved
# end to end: one program, two processes, dispatch by pin, with no new fixture,
# no new flag and no edited assertion elsewhere.
# ---------------------------------------------------------------------------
stubabs="$(cd .. && pwd)/test/stub_adapter.py"
mkdir -p "$work/two-adapters/bin"
cat > "$work/two-adapters/bin/stub-writing" <<EOF
#!/bin/sh
exec python3 "$stubabs" --write-on-ask "\$@"
EOF
chmod +x "$work/two-adapters/bin/stub-writing"

play two-adapters run harden --engine acp --adapter stub \
  --route "deep=acp:$work/two-adapters/bin/stub-writing" --timeout 60000
want_code 0
# The routed adapter answered the author, which is the pinned ask …
want_line "permission DENIED  to 'edit parse.c while answering' during the text question put to model author"
# … and the unpinned reviewers went to the default, which never asks to write.
want_no_line "during the text question put to model reviewer-correct"
want_no_line "during the verdict question put to model reviewer-secure"
# The denial held, and the act still ran — on the default adapter, in the one
# shared directory both backends were pointed at.
want_no_file parse.c
want_file applied.c
# Identical to scenario 1, because routing changes no bill: no field of an
# EventKey names a backend, so a route table cannot move a number.
want_bills 7 7
want_line "running harden against 2 backends:"
want_line "— every unpinned ask, every tool and every person"
grep -qE '^  deep +the .*stub-writing adapter: ' "$out" \
  || bad "the header does not put deep on its own line with its own adapter"
note "two-adapters: the pin went to the routed stub, everything else to the default, 7/7, exit 0"

# ---------------------------------------------------------------------------
# 14. A route to a dead adapter fails before anything is spent.
#
# `/usr/bin/false` starts and exits, so the pipe reaches EOF with the handshake
# outstanding — scenario 8's failure, reached through a route instead of through
# `--adapter`. What this scenario pins that scenario 8 cannot is *eager
# startup*: every routed backend is connected before the first question, so a
# run whose third backend will not start fails before its first backend answers
# anything. Under lazy startup this same command line would answer the `cat`
# question first and *then* fail, and `billFresh` would appear. Asserting its
# absence is asserting the startup order.
#
# It is also where the header is held to being *true before the first question
# is put*: `deep` and the program it was routed to are named in it, printed
# before the connect that failed, which is what lets an operator read a
# transport failure against their own command line.
# ---------------------------------------------------------------------------
play dead-route run harden --engine acp --adapter stub \
  --route 'deep=acp:/usr/bin/false' --timeout 10000
want_code 2
want_line "closed its output while the initialize handshake was outstanding"
want_line "/usr/bin/false"
grep -qE '^  deep +the /usr/bin/false adapter: ' "$out" \
  || bad "the header did not name the pin the dead backend was routed for"
want_no_line "billFresh"
note "dead-route: eager startup failed before anything was spent, exit 2"

# …and the other half of a true header: the pins this program has that no
# --route claims are printed on their own line, so that a mistyped route reads
# as a mistyped route and not as an absent one. `grind-tests` pins four models,
# which is why it is the fixture here and the flagship is not; the run dies at
# the same connect, so this costs no turns.
play unclaimed-pins run grind-tests --engine acp --adapter stub \
  --route 'opus=acp:/usr/bin/false' --timeout 10000
want_code 2
want_line "fable, gpt-5.5-xhigh, opencode  the default (no --route names them)"
want_no_line "billFresh"
note "unclaimed-pins: the header names the pins no route claims, exit 2"

# ---------------------------------------------------------------------------
# 15. The four usage refusals, none of which spawns anything.
#
# The same shape as scenario 12, which must itself stay green unedited: a flag
# silently accepted by the transport it means nothing to is a run configured by
# a line nobody read. Exit 1 in every case, before an adapter is spawned or a
# token is spent, and each asserted on its wording — which is the only part of a
# usage error anybody reads.
#
# The fifth refusal of the design — a malformed BACKEND — is `parseBackend`'s
# own and is pinned on its wording in ci/policies.sh, where it costs no process.
# ---------------------------------------------------------------------------
play route-scripted run harden --scripted --route 'deep=acp:codex'
want_code 1
want_line "--route names live backends and --scripted answers from a table; pick one"
want_no_line "billFresh"

play route-no-default run harden --route 'deep=acp:codex'
want_code 1
want_line "--route refines this run's default answerer, and there is none"
want_no_line "billFresh"

# The one worth defending: a route naming a model the program never pins has
# configured nothing, and its operator believes otherwise. `author` is a *party*
# and `deep` is what serves it — the resolution rule defended at the command
# line, where an operator will actually make the mistake.
play route-unpinned run harden --engine acp --route 'author=acp:codex'
want_code 1
want_line "--route names the model 'author', which this example never pins; the models it pins are: deep"
want_no_line "billFresh"

play route-twice run harden --engine acp --route 'deep=acp:codex' --route 'deep=acp:claude'
want_code 1
want_line "--route names the model 'deep' twice; a model has one backend in a run"
want_no_line "billFresh"
note "route-usage: four refusals, each before anything was spawned, exit 1"

# ---------------------------------------------------------------------------
# 16. An adapter that narrates itself into the answer stream.
#
# `test/acp-narrator.py` is the stub behind a proxy that writes the measured
# `claude-agent-acp` model-fallback banner into the head of every turn as an
# ordinary `agent_message_chunk` — in the model's voice, because the ACP schema
# has no field for a model substitution — and inspects every prompt going the
# other way for it. Both halves are the defect of `acat-owa`: the banner was
# part of the recorded answer, so a reviewer's APPROVE under it decoded as an
# objection (approval must be the WHOLE reply, the fail-closed rule), and the
# banner rode verbatim into every prompt that quoted that answer.
#
# `Exec.splitTransportNarration` separates it at the transport boundary, so:
# every one of the seven prompts is clean *as the adapter sees it*, which is the
# assertion no client-side log can make; the run bills 7/7 like scenario 1,
# because the verdicts are read as the approvals they are; and each separation
# is announced through `stderrLog`, unconditionally — the run must not be able
# to edit what an addressee appears to have said in silence.
#
# The negative control is not a flag but a measurement, taken by hand at
# `transportBanners = []` on this same command line: the banner rode into
# prompts 3 through 10, all three verdicts read as objections, the revision
# round it bought re-drafted the patch into the stub's "nothing canned for that"
# refusal, the panel objected again, and the run ended Unsettled — billFresh 13,
# billMemo 10, `applied.c` never written, exit 0. A run that quietly did
# nothing, which is why 7/7 here is the assertion and not the exit code.
# ---------------------------------------------------------------------------
play narrating-adapter run harden --engine acp --adapter test/acp-narrator.py --timeout 60000
want_code 0
# Every prompt clean, at the far end of the pipe: the first that quotes an
# answer, and the last, which quotes the patch the act is about to write.
want_line "acp-narrator: prompt 3 carried no transport banner"
want_line "acp-narrator: prompt 7 carried no transport banner"
want_no_line "CARRIED THE TRANSPORT BANNER"
# The banner did arrive — the separation was real work and not a vacuous pass —
# and it is named where the operator reads it, on a verdict, which is the
# question the defect was measured on.
want_line "agentic: transport narration separated from the answer to the verdict question put to model reviewer-correct: '**Model fallback:** claude-fable-5 declined this request (cyber)"
# Scenario 1's bills and scenario 1's artifact: a narrating adapter costs a run
# nothing once the narration is not part of the answer.
want_bills 7 7
want_file applied.c
grep -qF 'snprintf(buf, sizeof buf' "$state/applied.c" \
  || bad "applied.c does not hold the line the patch adds"
# And the run's own transcript: no recorded answer begins with the banner, which
# is the same fact from the other end — what the table holds is what travels.
want_no_line "<- **Model fallback:**"
note "narrating-adapter: the banner was separated and announced, 7/7 clean prompts, exit 0"

# ---------------------------------------------------------------------------

scenario=summary
if [ "$failures" = 0 ]; then
  echo "ci/acp: 16 scenarios passed, 0 failed"
else
  echo "ci/acp: $failures scenario assertion(s) failed" >&2
fi
exit $((failures > 0))
