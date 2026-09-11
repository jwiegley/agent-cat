#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Run through the configured project environment}"
umask 077
unset GHCRTS
bash test/cabal.sh build manager-profile-probe manager-root-probe --ghc-options=-Werror
profile_runner=$(bash test/cabal.sh list-bin manager-profile-probe)
root_runner=$(bash test/cabal.sh list-bin manager-root-probe)
work=$(mktemp -d "$CABAL_BUILDDIR/manager-profiles.XXXXXX")
python3 - "$profile_runner" "$root_runner" "$root" "$work" <<'PY'
from pathlib import Path
import subprocess
import sys
profile_runner, root_runner, source, destination = sys.argv[1:]
for capabilities in ("-N1", "-N8"):
    work = Path(destination) / capabilities[1:]
    temporary = work / "tmp"
    temporary.mkdir(parents=True)
    environment = {"TMPDIR": str(temporary), "PROFILE_CHECK_MANAGER_ONLY": "SYNTHETIC_MANAGER_ONLY"}
    print(f"profile checks {capabilities}", flush=True)
    subprocess.run([profile_runner, str(work), source, "+RTS", capabilities, "-RTS"], cwd=source, env=environment, check=True, timeout=120)
    print(f"root separation checks {capabilities}", flush=True)
    subprocess.run([root_runner, "+RTS", capabilities, "-RTS"], cwd=source, env=environment, check=True, timeout=60)
print(f"Private fixture evidence: {destination}")
PY
