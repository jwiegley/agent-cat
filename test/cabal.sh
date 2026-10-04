#!/usr/bin/env bash
set -euo pipefail

: "${CABAL_BUILDDIR:?Run this command through the configured project direnv}"
# sdist reads no package repository, and Cabal refuses --offline for it.
# Every other command sets the data directory of the package to this checkout,
# so that a built runner finds its data files from any working directory.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
command=("$1")
[[ $1 == sdist ]] || command+=(--offline "--datadir=$root" --datasubdir=.)
exec cabal --store-dir="$CABAL_BUILDDIR/cabal-store" --active-repositories=:none \
  "${command[@]}" --builddir="$CABAL_BUILDDIR" "${@:2}"
