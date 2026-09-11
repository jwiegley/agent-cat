#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${CABAL_BUILDDIR:?Run through the configured project environment}"
work=$(mktemp -d "$CABAL_BUILDDIR/capture.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/normal" "$work/fault" "$work/tmp"
export TMPDIR="$work/tmp"
unset GHCRTS
flags=(-Wall -Werror -O1 -threaded -rtsopts -optc-Wall -optc-Wextra -optc-Werror -iruntime/src -iruntime/test -iplan/src -idsl/src -icost/src -iengine/api/src)
ghc --make "${flags[@]}" -outputdir "$work/normal" \
  runtime/test/CaptureTests.hs runtime/cbits/private_directory.c runtime/cbits/private_sync.c runtime/cbits/process_group.c \
  -main-is CaptureTests.captureTests -o "$work/capture-tests"
ghc --make "${flags[@]}" -outputdir "$work/normal" \
  runtime/test/RootRoleTests.hs runtime/cbits/private_directory.c runtime/cbits/private_sync.c runtime/cbits/process_group.c \
  -main-is RootRoleTests.rootRoleTests -o "$work/root-role-tests"
ghc --make "${flags[@]}" -outputdir "$work/fault" \
  runtime/test/CaptureFaultTests.hs runtime/cbits/private_directory.c runtime/test/capture_sync_fault.c \
  -o "$work/capture-fault-tests"
python3 - "$work" <<'PY'
from pathlib import Path
import subprocess
import sys
for name in ("capture-tests", "root-role-tests", "capture-fault-tests"):
    for capabilities in ("-N1", "-N8"):
        print(f"{name} {capabilities}", flush=True)
        subprocess.run([str(Path(sys.argv[1]) / name), "+RTS", capabilities, "-RTS"], check=True, timeout=60)
PY
