#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Use the configured project environment}"
umask 077
unset GHCRTS
work=$(mktemp -d "$CABAL_BUILDDIR/supervision.XXXXXX")
python3 manager/test/supervision/check.py "$root" "$work/run"
