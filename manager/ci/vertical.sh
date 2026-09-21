#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Use the configured project environment}"
: "${TMPDIR:?Use a short private temporary root}"
umask 077
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import os
assert "GHCRTS" not in os.environ
assert not any(name.startswith("AGENT_CAT_") for name in os.environ)
PY
bash test/cabal.sh build manager-vertical-check manager-approval-check routing-fixed-point-probe --ghc-options=-Werror
checker=$(bash test/cabal.sh list-bin manager-vertical-check)
native=$(bash test/cabal.sh list-bin routing-fixed-point-probe)
python=$(command -v python3)
work=$(mktemp -d "$TMPDIR/v.XXXXXX")
printf 'Vertical lifecycle evidence: %s\n' "$work"
for capabilities in 1 8; do
  mkdir "$work/N$capabilities"
  "$checker" vertical "$work/N$capabilities" "$native" "$root" "$python" +RTS "-N$capabilities" -RTS 2>&1 | tee "$work/N$capabilities.log"
done
# Race and write-boundary checks require the existing instrumented captures.
for audit in history-corrections control-write; do
  python3 manager/test/admission_audit.py "$root" "$audit"
done
