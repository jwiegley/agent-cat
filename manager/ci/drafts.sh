#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Run through the configured project environment}"
umask 077
unset GHCRTS
bash test/cabal.sh build manager-draft-check --ghc-options=-Werror
runner=$(bash test/cabal.sh list-bin manager-draft-check)
work=$(mktemp -d "$CABAL_BUILDDIR/manager-drafts.XXXXXX")
for capabilities in N1 N8; do
  mkdir "$work/$capabilities"
  echo "manager draft checks -$capabilities"
  "$runner" "$work/$capabilities" "$root" +RTS "-$capabilities" -RTS 2>&1 | tee "$work/$capabilities.log"
  env PYTHONDONTWRITEBYTECODE=1 python3 manager/test/draft_contract.py "$root" "$work/$capabilities"
done
echo "Private draft evidence: $work"
