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
work=$(mktemp -d "$CABAL_BUILDDIR/ingestion.XXXXXX")
for capabilities in 1 8; do
  mkdir "$work/N$capabilities"
  "$checker" ingestion "$work/N$capabilities" "$native" "$root" "$python" +RTS "-N$capabilities" -RTS
done
python3 manager/test/admission_audit.py "$root" ingestion-retained-mutant
python3 manager/test/admission_audit.py "$root" ingestion-duplicate-mutant
python3 manager/test/admission_audit.py "$root" ingestion-race
python3 manager/test/admission_audit.py "$root" ingestion-race-mutant
python3 manager/test/admission_audit.py "$root" ingestion-cleanup-mutant
python3 manager/test/admission_audit.py "$root" ingestion-observer-mutant
