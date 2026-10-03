#!/usr/bin/env bash
set -euo pipefail

: "${CABAL_BUILDDIR:?Run this command through the configured project direnv}"
# sdist reads no package repository, and Cabal refuses --offline for it.
command=("$1")
[[ $1 == sdist ]] || command+=(--offline)
exec cabal --store-dir="$CABAL_BUILDDIR/cabal-store" --active-repositories=:none \
  "${command[@]}" --builddir="$CABAL_BUILDDIR" "${@:2}"
