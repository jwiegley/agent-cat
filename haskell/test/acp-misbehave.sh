#!/usr/bin/env bash
#
# An "ACP adapter" that misbehaves on purpose, for the two failures
# `agent-cat/test/stub_adapter.py` cannot produce — it is a *conforming*
# adapter, and these are the ways a non-conforming one breaks a client.
#
# One mode per argument, passed through `agentic-run --adapter-arg`:
#
#   babble   write prose on stdout instead of JSON-RPC, then wait. The client
#            must refuse the line by name (`AcpNotJson`) and quote it, rather
#            than read on hoping for something parseable.
#   mute     accept the handshake and answer nothing, ever. The turn budget is
#            the whole guard against a wedged adapter: it must produce a named
#            failure (`AcpTimedOut`) that says which question was outstanding,
#            and the child must be killed rather than left behind.
#
# Both modes then sleep, and `exec` is deliberate: the sleep *is* this process,
# so a client that kills the child kills the sleep, and a scenario that failed
# to kill it would hang the gate rather than pass it quietly. The odd duration
# is so that a stray one is identifiable as this script's and not some other
# tool's `sleep`.
#
# Not a general test double: `test/stub_adapter.py` is the one that speaks the
# protocol, and this exists only to be unspeakable.
set -u

mode="${1:-babble}"

case "$mode" in
  babble)
    echo 'I am not a JSON-RPC adapter, I am prose.'
    exec sleep 37
    ;;
  mute)
    exec sleep 37
    ;;
  *)
    echo "acp-misbehave: no mode '$mode'; there is babble and mute" >&2
    exit 2
    ;;
esac
