#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

isolated_config=$(mktemp -d)
trap 'rm -rf "$isolated_config"' EXIT
runghc -package=ghc test/source-boundaries.hs "$(ghc --print-libdir)"

if grep -E -n 'tree-sitter|cmark|microlens' agentic.cabal flake.nix; then
  echo "tui/ci/tui: unapproved highlighting dependency entered the package" >&2
  exit 1
fi

test/cabal.sh build -v0 -ftui-tests agentic-run tui-model-test tui-test-driver
test/cabal.sh test -v0 tui-model-test
runner=$(test/cabal.sh list-bin agentic-run)
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$isolated_config" python3 test/progress_probe.py "$runner"
driver=$(test/cabal.sh list-bin -ftui-tests tui-test-driver)
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$isolated_config" python3 test/tui_probe.py "$runner" --driver "$driver"
