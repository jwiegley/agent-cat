#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Run through the configured project environment}"
umask 077
unset GHCRTS
bash test/cabal.sh build manager-worker-check routing-fixed-point-probe --ghc-options=-Werror
runner=$(bash test/cabal.sh list-bin manager-worker-check)
native=$(bash test/cabal.sh list-bin routing-fixed-point-probe)
python=$(command -v python3)
work=$(mktemp -d "$CABAL_BUILDDIR/manager-workers.XXXXXX")
for capabilities in N1 N8; do
  mkdir "$work/$capabilities"
  echo "manager worker checks -$capabilities"
  env WM012_AMBIENT_SECRET=SYNTHETIC_NOT_FOR_WORKERS "$runner" "$work/$capabilities" "$root" "$native" "$python" +RTS "-$capabilities" -RTS 2>&1 | tee "$work/$capabilities.log"
  python3 manager/test/worker_evidence.py "$work/$capabilities" "$native"
done
python3 manager/test/proof_opacity.py "$root" "$work/opacity"
echo "Private worker evidence: $work"
