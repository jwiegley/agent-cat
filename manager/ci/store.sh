#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Run through the configured project environment}"
umask 077
unset GHCRTS
bash test/cabal.sh build manager-store-check --ghc-options=-Werror
runner=$(bash test/cabal.sh list-bin manager-store-check)
work=$(mktemp -d "$CABAL_BUILDDIR/manager-store.XXXXXX")
for capabilities in N1 N8; do
  mkdir "$work/$capabilities" "$work/restart-$capabilities"
  "$runner" restart "$work/restart-$capabilities" +RTS "-$capabilities" -RTS 2>&1 | tee "$work/restart-$capabilities.log"
  echo "manager storage checks -$capabilities"
  "$runner" "$work/$capabilities" +RTS "-$capabilities" -RTS 2>&1 | tee "$work/$capabilities.log"
  echo "manager admission primitive checks -$capabilities"
  "$runner" admission-data +RTS "-$capabilities" -RTS 2>&1 | tee "$work/$capabilities-admission-data.log"
  mkdir "$work/$capabilities-terminal-admission"
  echo "manager terminal admission checks -$capabilities"
  "$runner" terminal-admission "$work/$capabilities-terminal-admission" +RTS "-$capabilities" -RTS 2>&1 | tee "$work/$capabilities-terminal-admission.log"
done
echo "Private coordination storage evidence: $work"
python3 manager/test/admission_audit.py "$root" restore-interruption
python3 manager/test/admission_audit.py "$root" store-cancel-gap
python3 manager/test/admission_audit.py "$root" store-cancel-mutant
python3 manager/test/admission_audit.py "$root" store-expiry-mutant
