#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Run through the configured project environment}"
umask 077
unset GHCRTS
bash test/cabal.sh build manager-profile-probe manager-configuration-probe --ghc-options=-Werror
profile_runner=$(bash test/cabal.sh list-bin manager-profile-probe)
configuration_runner=$(bash test/cabal.sh list-bin manager-configuration-probe)
work=$(mktemp -d "$CABAL_BUILDDIR/manager-configuration.XXXXXX")
python3 - "$configuration_runner" "$profile_runner" "$root" "$work" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
configuration_runner, profile_runner, source, destination = sys.argv[1:]
for capabilities in ("-N1", "-N8"):
    work = Path(destination) / capabilities[1:]
    temporary = work / "tmp"
    temporary.mkdir(parents=True)
    for directory in (work, work.parent):
        descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    environment = {"TMPDIR": str(temporary), "PROFILE_CHECK_MANAGER_ONLY": "SYNTHETIC_MANAGER_ONLY"}
    print(f"configuration checks {capabilities}", flush=True)
    subprocess.run([configuration_runner, str(work), source, profile_runner, "+RTS", capabilities, "-RTS"], cwd=source, env=environment, check=True, timeout=180)
print(f"Private configuration evidence: {destination}")
PY
