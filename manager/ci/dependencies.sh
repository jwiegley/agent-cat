#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${CABAL_BUILDDIR:?Run this gate through the configured project direnv}"
build="$CABAL_BUILDDIR/manager-dependency-probe"
mkdir -p "$build"
work=$(mktemp -d "$build/fixture.XXXXXX")
trap 'rm -rf "$work"' EXIT

test/cabal.sh build lib:agentic
test/cabal.sh exec -- ghc -Wall -Werror -threaded \
  -package agentic -package direct-sqlite -package wai -package warp -package warp-tls \
  -package network -package tls -package crypton-connection -package crypton-x509-store \
  -outputdir "$build" manager/test/DependencyProbe.hs -o "$build/probe"
"$build/probe" "$work" +RTS -N2 -RTS
python3 manager/test/containment_probe.py
