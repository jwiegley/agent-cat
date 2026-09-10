#!/usr/bin/env bash
set -euo pipefail

: "${CABAL_BUILDDIR:?Run this command through the configured project direnv}"
exec cabal "$1" --offline --builddir="$CABAL_BUILDDIR" "${@:2}"
