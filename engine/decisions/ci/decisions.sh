#!/usr/bin/env bash
#
# The decisions gate: `Agentic.Decisions` against an in-process loopback stub.
#
# No Lean, no network and no paid endpoint. The test suite
# `engine-decisions-test` runs the pure wire adapter against the response
# fixtures in `test/fixtures` and runs the engine against a `warp` stub that
# listens on 127.0.0.1 inside the test process. Law L13, which reads every
# accepted answer at the decision's schema, needs the DSL, and the gate
# `cli/ci/policies.sh` checks it with `decision-probe`.
#
#     ./engine/decisions/ci/decisions.sh
#
# Before the suite, this script checks three source rules that the compiler
# cannot see:
#
#   1. The engine imports only the engine API and its own modules.
#   2. `Agentic.Decisions` names no vendor field. Every vendor field name
#      lives in `Agentic.Decisions.Wire`.
#   3. Each unconfirmed detail U1 to U17 that section 11 of
#      `doc/research/decision-models.md` lists is marked `UNCONFIRMED(Uk)` in
#      `Agentic.Decisions.Wire`.
#
# Exits 0 only if every rule holds and the suite passes.
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

failures=0
note() { echo "ci/decisions: $*"; }
bad() { echo "ci/decisions: FAIL $*" >&2; failures=$((failures + 1)); }

src=engine/decisions/src/Agentic
engine="$src/Decisions.hs"
wire="$src/Decisions/Wire.hs"

# 1. Imports of the engine sources, project modules only.
imports=$(grep -hE '^import +(qualified +)?Agentic\.' "$engine" "$wire" |
  sed -E 's/^import +(qualified +)?([A-Za-z.]+).*/\2/' | sort -u)
for module in $imports; do
  case "$module" in
    Agentic.Engine | Agentic.Engine.* | Agentic.Decisions | Agentic.Decisions.*) ;;
    *) bad "the engine imports $module, and it may import only the engine API" ;;
  esac
done
note "imports: $(echo "$imports" | tr '\n' ' ')"

# 2. Vendor field names, as string literals, outside the wire module.
for vendor_field in model state input questions answers criteria choices levels \
  probabilities probability noul predicate choice score legend usage \
  input_tokens output_tokens cost id error metadata limit_source detail; do
  if grep -qF "\"$vendor_field\"" "$engine"; then
    bad "Agentic.Decisions names the vendor field \"$vendor_field\""
  fi
done
note "Agentic.Decisions names no vendor field"

# 3. Every unconfirmed item of section 11 of doc/research/decision-models.md
# is marked beside its code.
for k in $(seq 1 17); do
  grep -qF "UNCONFIRMED(U$k):" "$wire" || bad "no UNCONFIRMED(U$k) mark in Agentic.Decisions.Wire"
done
note "UNCONFIRMED(U1) to UNCONFIRMED(U17) are marked"

# The suite.
if test/cabal.sh test engine-decisions-test --test-show-details=direct; then
  note "engine-decisions-test passed"
else
  bad "engine-decisions-test failed"
fi

if [ "$failures" = 0 ]; then
  echo "ci/decisions: every check passed"
else
  echo "ci/decisions: $failures check(s) failed" >&2
fi
exit $((failures > 0))
