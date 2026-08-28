#!/usr/bin/env bash
#
# stub-deck.sh — a fake `agent-deck`, for testing `Agentic.AgentDeck` without a
# live session.
#
# `ci/deck.sh` copies this file to `$DECK_STUB_STATE/bin/agent-deck` (so that
# the PATH lookup is exercised too) and points `agentic-run run --binary` at it.
# It implements exactly the three commands the adapter uses and refuses every
# other one loudly, so an adapter that grows a fourth command fails here rather
# than silently against a real deck:
#
#   agent-deck session send   <id> <message>
#   agent-deck session show   <id> --json
#   agent-deck session output <id> --json
#
# The shapes it answers with are the ones `Agentic.AgentDeck` parses:
# `{"status":…,"substate":…}` from `show` (the two fields `agent-deck list
# --json` really carries per session, checked against agent-deck 1.13.0) and
# `{"content":…,"timestamp":…}` from `output`.
#
# The three verbs still read as they do above at 1.13.0, and each takes
# `<id|title>` rather than an id alone — `session send <id|title> <message>`,
# `session show [id|title]`, `session output [id|title]` — which is why a gate
# comparing backend spellings cannot know two names for one pane are one pane.
#
# Everything it does is driven by two environment variables:
#
#   DECK_STUB_STATE  a directory this script owns; required
#   DECK_STUB_MODE   which scenario to play; default `happy`
#   DECK_STUB_BUSY   polls to report `running` after a send; default 1
#
# The modes, and what each one is for:
#
#   happy        the flagship settles: guide, patch, three approvals, consent,
#                a receipt. Seven turns, seven sends.
#   objects      every reviewer objects and every revision returns the *same*
#                patch, so the second and third review rounds ask questions
#                that were already answered. The run walks thirteen ask nodes
#                and this script is sent six messages: the difference is the
#                memo table, observed from outside the process.
#   undecodable  the owner answers the flag question with `maybe`, twice. The
#                run re-asks once with the nudge and then abandons.
#   stopped      `session show` reports `stopped`: nothing will answer.
#   hang         `session show` reports `running` forever: the turn outruns its
#                budget.
#   stale        a send never changes the reply's timestamp, so from the second
#                question on the adapter must refuse to read the previous
#                turn's text as this question's answer.
#   empty-stamp  replies carry timestamp:"", as Pi sessions do; an empty stamp
#                must degrade to the documented unstamped-reply path.

set -uo pipefail

STATE="${DECK_STUB_STATE:?stub-deck.sh: set DECK_STUB_STATE to a directory this script may own}"
MODE="${DECK_STUB_MODE:-happy}"
BUSY="${DECK_STUB_BUSY:-1}"

mkdir -p "$STATE"

seq_file="$STATE/seq"
reply_file="$STATE/reply"
busy_file="$STATE/busy"
sends_file="$STATE/sends"
prompts_file="$STATE/prompts"

read_num() { [ -f "$1" ] && cat "$1" || echo "${2:-0}"; }

# A shell string as a JSON string body: backslash, quote, tab, carriage return
# and newline escaped, and nothing else, because nothing else appears in what
# this stub says. gawk and gnused are what the devShell's stdenv provides;
# python3 and jq are on this machine but are not in `flake.nix`, and a fixture
# that needs a tool the shell does not promise is a fixture that fails on
# somebody else's checkout.
json_escape() {
  awk '
    { s = $0
      gsub(/\\/, "\\\\", s)
      gsub(/"/,  "\\\"", s)
      gsub(/\t/, "\\t",  s)
      gsub(/\r/, "\\r",  s)
      out = out sep s; sep = "\\n" }
    END { printf "%s", out }
  '
}

# The two texts `agent-cat/test/stub_adapter.py` answers with, so a stub run
# reads like the scripted one. The patch is a real unified diff because the
# act's prompt wraps it, and it is *stable*: the `objects` mode answers every
# revision with this same text, which is what makes the second review round
# ask a question the first one already answered.
GUIDE='House style: two-space indent, no tabs, every public name documented, and failures returned rather than raised.'
PATCH='--- a/src/parse.c
+++ b/src/parse.c
@@
-  char buf[64]; strcpy(buf, input);
+  char buf[64]; snprintf(buf, sizeof buf, "%s", input);'

# What this stub says to one rendered question.
#
# The question arrives as `Agentic.AgentDeck.renderQ` wrote it: a bracketed
# header naming the addressee, the scope axes and the answer format, a blank
# line, then the prompt. The answer code is read off the header's
# `answer (<code>):` line and the text questions are told apart by what the
# prompt starts with — the same prefix rule `Agentic.Exec.scriptedWorld` uses,
# and for the same reason: a substring key can match a prompt through an answer
# that was spliced into it.
answer_for() {
  local msg="$1" code prompt
  code=$(printf '%s\n' "$msg" | grep -m1 -o 'answer ([a-z]*)' | grep -o '(.*)' | tr -d '()')
  prompt=$(printf '%s\n' "$msg" | awk 'seen { print } !seen && /^$/ { seen = 1 }')

  case "$code" in
    ack) printf '%s' 'DONE'; return ;;
    flag)
      if [ "$MODE" = undecodable ]; then printf '%s' 'maybe'; else printf '%s' 'yes'; fi
      return ;;
    verdict)
      if [ "$MODE" = objects ]
      then printf '%s' 'OBJECTION: the buffer bound is still unchecked'
      else printf '%s' 'APPROVE'
      fi
      return ;;
  esac

  # A text question: the guide, a patch, or — for anything this fixture was not
  # written for — the prompt itself, which is the corpus's default world.
  case "$prompt" in
    'Write out the house style guide'*) printf '%s' "$GUIDE" ;;
    'Draft a patch satisfying:'*)       printf '%s' "$PATCH" ;;
    *'Revise this patch:'*)             printf '%s' "$PATCH" ;;
    *)                                  printf '%s' "$prompt" ;;
  esac
}

fail() { echo "stub-deck: $*" >&2; exit 2; }

[ "${1:-}" = session ] || fail "this stub implements 'session' only, not '${1:-<nothing>}'"
verb="${2:-}"
id="${3:-}"

case "$verb" in

  send)
    message="${4:-}"
    [ -n "$message" ] || fail "session send needs a message"
    { printf '=== send %s ===\n' "$(($(read_num "$sends_file") + 1))"
      printf '%s\n' "$message"; } >> "$prompts_file"
    answer_for "$message" > "$reply_file"
    echo $(($(read_num "$sends_file") + 1)) > "$sends_file"
    # `stale` is the whole point of the timestamp guard: the session says
    # something new and stamps it with the old time, which is indistinguishable
    # from having said nothing unless the adapter compares stamps.
    [ "$MODE" = stale ] || echo $(($(read_num "$seq_file") + 1)) > "$seq_file"
    echo "$BUSY" > "$busy_file"
    echo "sent to $id"
    ;;

  show)
    case "$MODE" in
      stopped) printf '{"id":"%s","title":"stub","status":"stopped","substate":""}\n' "$id" ;;
      hang)    printf '{"id":"%s","title":"stub","status":"running","substate":"working"}\n' "$id" ;;
      *)
        busy=$(read_num "$busy_file")
        if [ "$busy" -gt 0 ]; then
          echo $((busy - 1)) > "$busy_file"
          printf '{"id":"%s","title":"stub","status":"running","substate":"working"}\n' "$id"
        else
          printf '{"id":"%s","title":"stub","status":"waiting","substate":"idle-at-empty-prompt"}\n' "$id"
        fi
        ;;
    esac
    ;;

  output)
    # A session that has not said anything yet is not an error to the adapter —
    # it is the ordinary state before the first turn — but the real CLI has
    # nothing to print either, so this exits nonzero and the adapter reads that
    # as "no output yet".
    [ -f "$reply_file" ] || fail "session $id has produced no output yet"
    stamp="stub-$(read_num "$seq_file")"
    [ "$MODE" = empty-stamp ] && stamp=
    printf '{"content":"%s","timestamp":"%s"}\n' \
      "$(json_escape < "$reply_file")" "$stamp"
    ;;

  *)
    fail "this stub implements send, show and output only, not 'session ${verb:-<nothing>}'"
    ;;
esac
