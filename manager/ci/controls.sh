#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Use the configured project environment}"
umask 077
unset GHCRTS
bash test/cabal.sh build manager-approval-check routing-fixed-point-probe --ghc-options=-Werror
checker=$(bash test/cabal.sh list-bin manager-approval-check)
native=$(bash test/cabal.sh list-bin routing-fixed-point-probe)
python=$(command -v python3)
work=$(mktemp -d "$CABAL_BUILDDIR/controls.XXXXXX")
printf 'Control evidence: %s\n' "$work"
for capabilities in 1 8; do
  for scenario in controls controls-live controls-steering controls-saturation controls-reload ingestion-concurrent; do
    fixture="$work/N$capabilities-$scenario"
    mkdir "$fixture"
    if [[ "$scenario" == controls || "$scenario" == controls-reload ]]; then
      "$checker" "$scenario" "$fixture" "$native" +RTS "-N$capabilities" -RTS
    else
      "$checker" "$scenario" "$fixture" "$native" "$root" "$python" +RTS "-N$capabilities" -RTS
    fi
    if [[ "$scenario" == controls || "$scenario" == controls-steering || "$scenario" == controls-saturation ]]; then
      "$python" manager/test/approval_contract.py "$root" "$fixture"
    fi
  done
done
for audit in control-reservation-mutant control-body-mutant control-release-mutant control-fifo-mutant control-unsupported control-unsupported-mutant control-steer-observation-mutant control-write control-interruption control-ticket-mutant control-reload-race control-preparation control-preparation-mutant; do
  "$python" manager/test/admission_audit.py "$root" "$audit"
done
