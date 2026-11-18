#!/usr/bin/env bash
#
# The decisions smoke: the `triage` example with its three decisions put to a
# hosted decisions endpoint.
#
#     AGENT_CAT_DECISIONS_LIVE=spend ./engine/decisions/ci/route-live.sh
#
# MANUAL ONLY. Never in an automatic lane, and no other gate calls it: it
# spends real money on a real account. It refuses to run unless the variable
# AGENT_CAT_DECISIONS_LIVE holds the word `spend`, so that a run is always an
# operator's explicit choice. The deterministic gate for the same path is
# engine/decisions/ci/triage.sh, which uses a stub on the loopback interface.
#
# The routing file is written here. The profile `triage` is routed to one
# hosted decisions model, and the desks are routed to the deterministic ACP
# stub adapter, so only the three decisions are paid for. The endpoint, its
# dialect and the model are taken from the environment, with these defaults:
#
#   AGENT_CAT_DECISIONS_URL      https://openrouter.ai/api/alpha/decisions
#   AGENT_CAT_DECISIONS_DIALECT  system-one
#   AGENT_CAT_DECISIONS_MODEL    typesafe/jev-1.14
#   AGENT_CAT_DECISIONS_SECRET   OPENROUTER_API_KEY, the name of the variable
#                                that holds the bearer token
#
# Exits 0 only if every assertion below held.
#
# WHAT THIS PROVES AND WHAT IT DOES NOT. It proves that a hosted endpoint
# answered each decision with a record that the runtime decoded, and that the
# run then reached exactly one desk under the priced bill of 4. It does not
# pin which desk, because the probabilities are the model's own.
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

if [ "${AGENT_CAT_DECISIONS_LIVE:-}" != spend ]; then
  echo "ci/decisions-live: this script contacts a paid decisions endpoint" >&2
  echo "ci/decisions-live: set AGENT_CAT_DECISIONS_LIVE=spend to run it" >&2
  exit 1
fi

url=${AGENT_CAT_DECISIONS_URL:-https://openrouter.ai/api/alpha/decisions}
dialect=${AGENT_CAT_DECISIONS_DIALECT:-system-one}
model=${AGENT_CAT_DECISIONS_MODEL:-typesafe/jev-1.14}
secret=${AGENT_CAT_DECISIONS_SECRET:-OPENROUTER_API_KEY}

case "$dialect" in
  system-one | openai) ;;
  *) echo "ci/decisions-live: AGENT_CAT_DECISIONS_DIALECT is system-one or openai, not '$dialect'" >&2; exit 1 ;;
esac
[ -n "${!secret:-}" ] || {
  echo "ci/decisions-live: the variable $secret is unset, and the endpoint needs its token" >&2
  exit 1
}

failures=0
note() { echo "ci/decisions-live: $*"; }
bad() { echo "ci/decisions-live: FAIL $*" >&2; failures=$((failures + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/agentic-decisions-live.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/config/agent-cat" "$work/cache"
cat > "$work/config/agent-cat/routing.yaml" <<EOF
version: 2
default-persona: live
secrets:
  decisions: { env: $secret }
engines:
  live-decisions:
    backend: decisions:$dialect
    provider: live
    endpoint:
      url: $url
      auth: { header: authorization, scheme: bearer, secret: decisions }
      timeout-ms: 30000
      max-bytes: 1048576
  acp-stub:
    backend: acp:stub
    provider: fixture
models:
  live: { engine: live-decisions, select: [ { exact: "$model" } ] }
  desk: { engine: acp-stub, select: [ { exact: stub-default } ] }
personas:
  live:
    engines: [live-decisions, acp-stub]
    models: [live, desk]
    profiles:
      triage:
        chain: [ { model: live } ]
      balanced:
        chain: [ { model: desk, thinking: high, max-output: 65536 } ]
EOF

printf '%s\n' 'I was charged twice this month. Please refund the second charge.' > "$work/ticket"

test/cabal.sh build -v0 exe:agentic-run > "$work/build" 2>&1 \
  || { echo "ci/decisions-live: the build failed:" >&2; cat "$work/build" >&2; exit 1; }
bin=$(test/cabal.sh list-bin exe:agentic-run 2> /dev/null | tail -1)

env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$work/config" XDG_CACHE_HOME="$work/cache" \
  "$bin" run triage --routing --input-file "ticket=$work/ticket" \
  < /dev/null > "$work/stdout" 2> "$work/stderr"
code=$?
show() { printf '\n  %s' "$(cat "$work/stdout" "$work/stderr")"; }

[ "$code" = 0 ] || bad "exit $code, wanted 0; output was:$(show)"
grep -qF "  triage = decisions:$dialect; live/$model; thinking off" "$work/stdout" \
  || bad "the profile triage is not routed to $model; output was:$(show)"
answers=$(grep -cE '^    <- \{' "$work/stdout")
[ "$answers" = 3 ] || bad "$answers decision records were printed, and 3 were wanted"
desks=$(grep -cE -- '^  effect ack -> model (refund-desk|billing-desk|support-desk|on-call|triage-desk): ' "$work/stdout")
[ "$desks" = 1 ] || bad "$desks desks were asked, and exactly 1 was wanted"
grep -qE '^    billFresh   4 ' "$work/stdout" || bad "billFresh is not 4; output was:$(show)"
grep -qE '^    billMemo    4 ' "$work/stdout" || bad "billMemo is not 4; output was:$(show)"

if [ "$failures" = 0 ]; then
  note "$model at $url answered three decisions; one desk asked; 4/4, exit 0"
  grep -E '^    <- \{|^  effect ack -> model ' "$work/stdout" | cut -c1-120
else
  echo "ci/decisions-live: $failures check(s) failed" >&2
fi
exit $((failures > 0))
