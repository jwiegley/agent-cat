#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Use the configured project environment}"
umask 077
unset GHCRTS
bash test/cabal.sh build manager-approval-check routing-fixed-point-probe --ghc-options=-Werror
checker=$(bash test/cabal.sh list-bin manager-approval-check)
python3 manager/test/admission_audit.py "$root" history-corrections
python3 manager/test/admission_audit.py "$root" history-policy
native=$(bash test/cabal.sh list-bin routing-fixed-point-probe)
python=$(command -v python3)
work=$(mktemp -d "$CABAL_BUILDDIR/manager-approval.XXXXXX")
for capabilities in N1 N8; do
  mkdir "$work/$capabilities" "$work/shutdown-drain-$capabilities"
  "$checker" shutdown-drain "$work/shutdown-drain-$capabilities" "$native" +RTS "-$capabilities" -RTS 2>&1 | tee "$work/shutdown-drain-$capabilities.log"
  "$checker" "$work/$capabilities" "$native" "$root" "$python" +RTS "-$capabilities" -RTS 2>&1 | tee "$work/$capabilities.log"
  python3 manager/test/approval_contract.py "$root" "$work/$capabilities"
done
python3 manager/test/proof_opacity.py "$root" "$work/opacity"
python3 manager/test/admission_audit.py "$root" shutdown-races
python3 manager/test/admission_audit.py "$root" approval-interruption
python3 manager/test/admission_audit.py "$root" approval-live-mutant
python3 manager/test/admission_audit.py "$root" approval-review-gap
for mutant in approval-publication-mutant approval-catalogue-mutant approval-reservation-mutant approval-quoted-mutant approval-delimiter-mutant approval-supervision-mutant approval-live-target-mutant; do
  python3 manager/test/admission_audit.py "$root" "$mutant"
done
echo "Private approval evidence: $work"
