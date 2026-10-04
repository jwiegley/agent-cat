#!/usr/bin/env python3
"""Check Cabal argument, working-directory, environment, and exit preservation."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


helper = Path(__file__).resolve().with_name("cabal.sh")
checkout = str(helper.parent.parent)
with tempfile.TemporaryDirectory(prefix="agentic-cabal-env-", delete=False) as temporary:
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
        reply = subprocess.run(["bash", str(helper), command, *arguments], cwd=root,
                               env=env, capture_output=True, text=True, timeout=10)
        assert reply.returncode == 23, reply
        assert reply.stderr == "", reply.stderr
        assert json.loads(reply.stdout) == [
            [f"--store-dir={builddir}/cabal-store", "--active-repositories=:none",
             command, "--offline", f"--datadir={checkout}", "--datasubdir=.",
             f"--builddir={builddir}", *arguments],
            str(root.resolve()), "fixture environment",
        ], reply.stdout
    # sdist reads no package repository, and Cabal refuses --offline for it.
    reply = subprocess.run(["bash", str(helper), "sdist", *arguments], cwd=root,
                           env=env, capture_output=True, text=True, timeout=10)
    assert reply.returncode == 23, reply
    assert reply.stderr == "", reply.stderr
    assert json.loads(reply.stdout) == [
        [f"--store-dir={builddir}/cabal-store", "--active-repositories=:none",
         "sdist", f"--builddir={builddir}", *arguments],
        str(root.resolve()), "fixture environment",
    ], reply.stdout
    # Without CABAL_BUILDDIR, the build directory is dist-newstyle in the
    # current directory.
    del env["CABAL_BUILDDIR"]
    reply = subprocess.run(["bash", str(helper), "build"], cwd=root, env=env,
                           capture_output=True, text=True, timeout=10)
    assert reply.returncode == 23 and reply.stderr == "", reply
    default = f"{root.resolve()}/dist-newstyle"
    assert json.loads(reply.stdout)[0] == [
        f"--store-dir={default}/cabal-store", "--active-repositories=:none",
        "build", "--offline", f"--datadir={checkout}", "--datasubdir=.", f"--builddir={default}",
    ], reply.stdout
assert root.is_dir() and binary.is_file(), "cabal environment evidence was not retained"
print("cabal environment: offline/data-directory/build-directory flags, the dist-newstyle default, sdist without --offline, argv, cwd, environment, and exit status preserved")
