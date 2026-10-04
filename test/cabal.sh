#!/usr/bin/env bash
set -euo pipefail

# The project environment sets CABAL_BUILDDIR. Without it, the build products
# and the isolated Cabal store go to dist-newstyle in the current directory.
: "${CABAL_BUILDDIR:=$PWD/dist-newstyle}"
# sdist reads no package repository, and Cabal refuses --offline for it.
# Every other command sets the data directory of the package to this checkout,
# so that a built runner finds its data files from any working directory.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
command=("$1")
[[ $1 == sdist ]] || command+=(--offline "--datadir=$root" --datasubdir=.)
exec cabal --store-dir="$CABAL_BUILDDIR/cabal-store" --active-repositories=:none \
  "${command[@]}" --builddir="$CABAL_BUILDDIR" "${@:2}"
