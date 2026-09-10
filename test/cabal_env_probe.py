#!/usr/bin/env python3
"""Check Cabal argument, working-directory, environment, and exit preservation."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


helper = Path(__file__).resolve().with_name("cabal.sh")
with tempfile.TemporaryDirectory(prefix="agentic-cabal-env-") as temporary:
    root = Path(temporary)
    binary = root / "cabal"
    binary.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, sys\n"
        "print(json.dumps([sys.argv[1:], os.getcwd(), os.environ['GATE_MARKER']]))\n"
        "raise SystemExit(23)\n"
    )
    binary.chmod(0o755)
    builddir = str(root / "build products")
    env = dict(os.environ, PATH=f"{root}{os.pathsep}{os.environ['PATH']}",
               CABAL_BUILDDIR=builddir, GATE_MARKER="fixture environment")
    arguments = ["--", "argument with spaces", "α雪", ""]
    for command in ["build", "test", "run", "exec", "list-bin", "repl"]:
        reply = subprocess.run([str(helper), command, *arguments], cwd=root,
                               env=env, capture_output=True, text=True, timeout=10)
        assert reply.returncode == 23, reply
        assert reply.stderr == "", reply.stderr
        assert json.loads(reply.stdout) == [
            [command, "--offline", f"--builddir={builddir}", *arguments],
            str(root.resolve()), "fixture environment",
        ], reply.stdout
    del env["CABAL_BUILDDIR"]
    reply = subprocess.run([str(helper), "build"], cwd=root, env=env,
                           capture_output=True, text=True, timeout=10)
    assert reply.returncode != 0 and reply.stdout == "", reply
    assert "configured project direnv" in reply.stderr, reply.stderr
print("cabal environment: offline/build-directory flags, argv, cwd, environment, and exit status preserved")
