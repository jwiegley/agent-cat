#!/usr/bin/env python3
"""Check source discovery, including executable and conditional Cabal roots."""

import json
from pathlib import Path
import subprocess
import tempfile

checker = Path(__file__).resolve().with_name("source-boundaries.hs")
libdir = subprocess.check_output(["ghc", "--print-libdir"], text=True).strip()
with tempfile.TemporaryDirectory(prefix="agentic-source-roots-") as temporary:
    root = Path(temporary)
    for directory in ["dsl/src", "plan/src", "cost/src", "runtime/src", "engine",
                      "bisim/haskell/src", "manager", "tui/src", "cli/src",
                      "cli/example", "workflow", "cli/run", "cli/conditional"]:
        (root / directory).mkdir(parents=True, exist_ok=True)
    (root / "agentic.cabal").write_text(
        "cabal-version: 3.0\nname: roots-fixture\nversion: 0.1.0.0\nbuild-type: Simple\n"
        "flag optional-roots\n  default: False\n  manual: True\n"
        "library\n  hs-source-dirs: dsl/src\n  exposed-modules: Example\n"
        "executable cli-fixture\n  main-is: Main.hs\n  hs-source-dirs: cli/run\n"
        "  if flag(optional-roots)\n    hs-source-dirs: cli/conditional\n    buildable: False\n"
    )
    fixtures = root / "test/fixtures/tui/import-boundaries.json"
    fixtures.parent.mkdir(parents=True)
    fixtures.write_text(json.dumps([{
        "name": "composition root permission", "layer": "cli/run",
        "source": "module Main where\nimport Agentic.Cli\n", "allowed": True,
    }]))
    (root / "cli/run/Main.hs").write_text("module Main where\nimport Agentic.Cli\n")

    def run() -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["runghc", "-package=ghc", "-package=Cabal-syntax", str(checker), libdir],
            cwd=root, capture_output=True, text=True, timeout=30,
        )

    valid = run()
    assert valid.returncode == 0, (valid.stdout, valid.stderr)
    for directory in ["cli/run", "cli/conditional"]:
        source = root / directory / "Agentic/Manager/Escape.hs"
        source.parent.mkdir(parents=True)
        source.write_text("module Agentic.Manager.Escape where\nimport Agentic.Cli\n")
        invalid = run()
        assert invalid.returncode != 0 and "manager namespace is outside" in invalid.stderr, (
            directory, invalid.returncode, invalid.stdout, invalid.stderr,
        )
        source.unlink()
print("source discovery: executable and disabled-conditional roots cannot bypass manager ownership")
