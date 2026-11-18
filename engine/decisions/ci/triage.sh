#!/usr/bin/env bash
#
# The Triage gate: the `triage` example through `agentic-run run --routing`,
# against a decisions stub on the loopback interface.
#
#     ./engine/decisions/ci/triage.sh
#
# No Lean, no network beyond 127.0.0.1 and no paid endpoint. The decisions
# endpoint is `engine/decisions/test/stub_decisions.py`, which answers both
# dialects from one table keyed by the instructions of each question, and the
# desks are answered by the deterministic ACP stub adapter that
# engine/acp/ci/acp.sh uses. The routing file is
# `engine/decisions/test/triage-routing.yaml` with the stub's port written
# into it, and each scenario selects one of its personas.
#
# Each scenario runs once for each dialect, `system-one` and `openai`:
#
#   1. answer    The three decisions are answered from the first rung. The
#                answers equal the rows of the scripted table, so the run
#                takes the refund-desk path and bills 4 fresh and 4 memo.
#   2. failover  The first rung answers HTTP 529. Every decision fails over
#                to the second rung, which answers, and the run is the run of
#                scenario 1.
#   3. abandon   The first rung answers HTTP 529 and the second refuses the
#                question. No rung is left, so the run is abandoned with exit
#                3 and asks no desk.
#   4. mixed     The first rung answers HTTP 529 and the second rung is the
#                generative stub adapter. The question fails over to it, and
#                the adapter answers with its fixed text for a prompt that it
#                has no canned answer for. That text is not a number record,
#                so the question is asked again, and then the run is
#                abandoned with exit 3.
#
# Exits 0 only if every scenario behaved exactly as written below.
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

python=$(type -P python3) || { echo "ci/triage: python3 is not on PATH" >&2; exit 1; }
stub="engine/decisions/test/stub_decisions.py"
template="engine/decisions/test/triage-routing.yaml"
for file in "$stub" "$template" engine/acp/test/stub_adapter.py; do
  [ -f "$file" ] || { echo "ci/triage: no $file" >&2; exit 1; }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/agentic-triage.XXXXXX")"
stub_pid=""
cleanup() {
  if [ -n "$stub_pid" ]; then
    kill "$stub_pid" 2> /dev/null
    wait "$stub_pid" 2> /dev/null
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

failures=0
scenario=""
note() { echo "ci/triage: $*"; }
bad() { echo "ci/triage: FAIL [$scenario] $*" >&2; failures=$((failures + 1)); }

test/cabal.sh build -v0 exe:agentic-run > "$work/build" 2>&1 \
  || { echo "ci/triage: the build failed:" >&2; cat "$work/build" >&2; exit 1; }
bin=$(test/cabal.sh list-bin exe:agentic-run 2> /dev/null | tail -1)
[ -x "$bin" ] || { echo "ci/triage: no agentic-run binary: '$bin'" >&2; exit 1; }

# The stub binds a port that the system chooses and writes it to a file. It
# exits by itself when this shell is gone, and the trap above stops it first.
"$python" "$stub" "$work/port" "$work/requests" "$$" &
stub_pid=$!
for _ in $(seq 1 200); do
  [ -s "$work/port" ] && break
  kill -0 "$stub_pid" 2> /dev/null || { echo "ci/triage: the stub exited before it listened" >&2; exit 1; }
  sleep 0.05
done
[ -s "$work/port" ] || { echo "ci/triage: the stub wrote no port" >&2; exit 1; }
port=$(cat "$work/port")
note "decisions stub listening on 127.0.0.1:$port"

mkdir -p "$work/config/agent-cat" "$work/cache"
sed "s/@PORT@/$port/g" "$template" > "$work/config/agent-cat/routing.yaml"

ticket="$work/ticket"
printf '%s\n' 'I was charged twice this month. Please refund the second charge.' > "$ticket"

# The answers of the scripted table, as the trace of a scripted run prints
# them. A routed run that reaches the stub must print the same three records.
"$bin" run triage --scripted --input-file "ticket=$ticket" < /dev/null > "$work/scripted" 2>&1 \
  || { echo "ci/triage: the scripted run failed:" >&2; cat "$work/scripted" >&2; exit 1; }
grep -E '^    <- \{' "$work/scripted" | sort > "$work/scripted.answers"
[ "$(wc -l < "$work/scripted.answers")" = 3 ] \
  || { echo "ci/triage: the scripted run printed no three records:" >&2; cat "$work/scripted" >&2; exit 1; }

# Run one scenario under one persona. The trace is on stdout and the narration
# on stderr. The two are kept apart, because concurrent narration may split a
# line of the other stream.
play() {
  scenario="$1"
  local persona="$2"
  state="$work/$scenario"
  mkdir -p "$state"
  : > "$work/requests"
  env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$work/config" XDG_CACHE_HOME="$work/cache" \
    "$bin" run triage --routing --persona "$persona" --input-file "ticket=$ticket" +RTS -N8 -RTS \
    < /dev/null > "$state/stdout" 2> "$state/stderr"
  code=$?
  cp "$work/requests" "$state/requests"
}

show() { printf '\n  %s' "$(cat "$state/stdout" "$state/stderr")"; }
want_code() { [ "$code" = "$1" ] || bad "exit $code, wanted $1; output was:$(show)"; }
want_out() { grep -qF -- "$1" "$state/stdout" || bad "no trace line containing '$1'; output was:$(show)"; }
want_no_out() { grep -qF -- "$1" "$state/stdout" && bad "a trace line contains '$1', and none should"; return 0; }
want_err() { grep -qF -- "$1" "$state/stderr" || bad "stderr holds no '$1'; output was:$(show)"; }

# The requests that the stub received for one model, as "type instructions".
requests_for() {
  "$python" - "$state/requests" "$1" <<'PY'
import json
import sys

for line in open(sys.argv[1], encoding="utf-8"):
    entry = json.loads(line)
    if entry["model"] == sys.argv[2]:
        print(entry["dialect"], entry["type"], entry["instructions"])
PY
}

# The three requests of one complete set of decisions, in a fixed order.
expected_requests() {
  local dialect=$1 yes_no
  case "$dialect" in
    system-one) yes_no=noul ;;
    openai) yes_no=predicate ;;
  esac
  printf '%s\n' \
    "$dialect score How urgent is this ticket?" \
    "$dialect $yes_no The customer explicitly asks for money back." \
    "$dialect choice Which team should handle this ticket?"
}

want_requests() {
  local model=$1 dialect=$2
  local actual expected
  actual=$(requests_for "$model" | sort)
  expected=$(expected_requests "$dialect" | sort)
  [ "$actual" = "$expected" ] \
    || bad "the stub received for $model:$(printf '\n  %s' "$actual")
wanted:$(printf '\n  %s' "$expected")"
}

want_no_requests() {
  local model=$1
  [ -z "$(requests_for "$model")" ] || bad "the stub received a request for $model, and none was wanted"
}

# The refund-desk path with the scripted probabilities.
want_refund_path() {
  grep -E '^    <- \{' "$state/stdout" | sort > "$state/answers"
  cmp -s "$state/answers" "$work/scripted.answers" \
    || bad "the answers differ from the scripted table:$(printf '\n  %s' "$(cat "$state/answers")")"
  [ "$(grep -c '^  consult structured -> model triage: ' "$state/stdout")" -ge 3 ] \
    || bad "fewer than three decisions were put; output was:$(show)"
  want_out "  effect ack -> model refund-desk: Prepare the refund this ticket asks for."
  grep -qE -- '-> model (billing-desk|support-desk|on-call|triage-desk):' "$state/stdout" \
    && bad "a desk other than refund-desk was asked"
  want_out "    billFresh   4 "
  want_out "    billMemo    4 "
}

for dialect in system-one openai; do
  # 1. The decisions are answered from the first rung.
  play "$dialect-answer" "$dialect"
  want_code 0
  want_out "  triage = decisions:$dialect; fixture/stub-good; thinking off"
  want_out "  balanced = acp:stub; fixture/stub-default; thinking high; max-output 65536"
  want_refund_path
  want_requests stub-good "$dialect"
  note "$dialect-answer: three decisions answered by the $dialect stub, refund-desk taken, 4/4, exit 0"

  # 2. A busy first rung fails over to a second decisions model.
  play "$dialect-failover" "$dialect-failover"
  want_code 0
  want_out "  triage#2 = decisions:$dialect; fixture/stub-good; thinking off"
  want_refund_path
  want_requests stub-busy "$dialect"
  want_requests stub-good "$dialect"
  note "$dialect-failover: each decision met HTTP 529 and was answered by the second rung, refund-desk taken, 4/4, exit 0"

  # 3. A busy rung and a refusing rung, and no rung after them.
  play "$dialect-abandon" "$dialect-abandon"
  want_code 3
  want_err "the decisions engine could not answer model triage: the model refused the question"
  want_no_out "the run is over."
  want_no_out "billFresh"
  want_no_out "effect ack -> model"
  [ -n "$(requests_for stub-busy)" ] || bad "the busy rung received no request"
  [ -n "$(requests_for stub-refusing)" ] || bad "the refusing rung received no request"
  want_no_requests stub-good
  note "$dialect-abandon: HTTP 529, then a refusal, then no rung left; abandoned before any desk, exit 3"

  # 4. A busy decisions rung fails over to the generative stub adapter.
  play "$dialect-mixed" "$dialect-mixed"
  want_code 3
  want_out "  triage#2 = acp:stub; fixture/stub-default; thinking high; max-output 65536"
  [ "$(grep -c '^  consult structured -> model triage: ' "$state/stdout")" -ge 2 ] \
    || bad "the decision was not put to the second rung; output was:$(show)"
  want_err "after 2 attempts; last reply: 'I have nothing canned for that.'"
  want_no_out "the run is over."
  want_no_out "effect ack -> model"
  [ -n "$(requests_for stub-busy)" ] || bad "the busy rung received no request"
  [ "$(wc -l < "$state/requests")" = "$(requests_for stub-busy | wc -l)" ] \
    || bad "the stub received a request for a model other than stub-busy"
  note "$dialect-mixed: HTTP 529 failed over to acp:stub, whose fixed text is no number record; abandoned, exit 3"
done

if [ "$failures" = 0 ]; then
  echo "ci/triage: every scenario behaved as written"
else
  echo "ci/triage: $failures check(s) failed" >&2
fi
exit $((failures > 0))
