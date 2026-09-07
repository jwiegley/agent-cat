#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

isolated_config=$(mktemp -d)
trap 'rm -rf "$isolated_config"' EXIT
nix develop path:. -c bash -c 'runghc -package=ghc test/source-boundaries.hs "$(ghc --print-libdir)"'

if grep -E -n 'tree-sitter|cmark|microlens' agentic.cabal flake.nix; then
  echo "tui/ci/tui: unapproved highlighting dependency entered the package" >&2
  exit 1
fi

nix develop path:. -c cabal build -v0 -ftui-tests agentic-run tui-model-test tui-test-driver
nix develop path:. -c cabal test -v0 tui-model-test
runner=$(nix develop path:. -c cabal list-bin agentic-run)
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$isolated_config" python3 test/progress_probe.py "$runner"
driver=$(nix develop path:. -c cabal list-bin -ftui-tests tui-test-driver)
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$isolated_config" python3 test/tui_probe.py "$runner" --driver "$driver"
