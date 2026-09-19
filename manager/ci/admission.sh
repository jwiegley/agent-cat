#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Run through the configured project environment}"
umask 077
unset GHCRTS
bash test/cabal.sh build manager-admission-check routing-fixed-point-probe --ghc-options=-Werror
runner=$(bash test/cabal.sh list-bin manager-admission-check)
native=$(bash test/cabal.sh list-bin routing-fixed-point-probe)
python=$(command -v python3)
work=$(mktemp -d "$CABAL_BUILDDIR/manager-admission.XXXXXX")
for capabilities in N1 N8; do
  mkdir "$work/$capabilities" "$work/shutdown-only-$capabilities" "$work/shutdown-native-$capabilities"
  "$runner" shutdown-only "$work/shutdown-only-$capabilities" +RTS "-$capabilities" -RTS 2>&1 | tee "$work/shutdown-only-$capabilities.log"
  "$runner" shutdown-native "$work/shutdown-native-$capabilities" "$native" +RTS "-$capabilities" -RTS 2>&1 | tee "$work/shutdown-native-$capabilities.log"
  "$runner" "$work/$capabilities" "$native" "$root" "$python" +RTS "-$capabilities" -RTS 2>&1 | tee "$work/$capabilities.log"
done
python3 manager/test/proof_opacity.py "$root" "$work/opacity"
python3 manager/test/admission_audit.py "$root" package-boundary
python3 manager/test/admission_audit.py "$root" interruption
echo "Private admission evidence: $work"
