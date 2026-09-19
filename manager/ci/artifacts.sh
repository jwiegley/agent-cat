#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Use the configured project environment}"
umask 077
unset GHCRTS
export PYTHONDONTWRITEBYTECODE=1
bash test/cabal.sh build lib:agentic manager-artifact-check --ghc-options=-Werror
checker=$(bash test/cabal.sh list-bin manager-artifact-check)
work=$(mktemp -d "${TMPDIR:?Use a short private temporary root}/artifacts.XXXXXX")
printf 'Artifact evidence: %s\n' "$work"
# Pure/SQLite/filesystem only. Each process has a 512MiB heap and 120-second ceiling.
for capabilities in 1 8; do
  fixture="$work/N$capabilities"
  mkdir "$fixture"
  python3 - "$checker" "$fixture" "$root" "$capabilities" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
assert "GHCRTS" not in os.environ
assert not any(name.startswith("AGENT_CAT_") for name in os.environ)
checker, fixture, root, capabilities = sys.argv[1:]
with (Path(fixture) / "check.log").open("wb") as log:
    result = subprocess.run([checker, fixture, root, "+RTS", "-N" + capabilities, "-M512m", "-RTS"], stdout=log, stderr=subprocess.STDOUT, timeout=120)
raw = (Path(fixture) / "check.log").read_bytes()
assert b"synthetic-token" not in raw and b"<script>" not in raw and b"\x1b[31m" not in raw
sys.stdout.buffer.write(raw)
assert result.returncode == 0, "artifact check failed; original log retained"
PY
  python3 manager/test/artifact_contract.py "$root" "$fixture"
done
