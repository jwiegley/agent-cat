#!/usr/bin/env python3
"""Compile real source consumers, with a positive environment control."""
from pathlib import Path
import json
import os
import subprocess
import sys

source, work = map(Path, sys.argv[1:])
work.mkdir()
plan = json.loads((Path(os.environ["CABAL_BUILDDIR"]) / "cache/plan.json").read_text())
units = [item["id"] for item in plan["install-plan"]
         if item.get("pkg-name") == "agentic" and item.get("component-name") == "lib"
         and item.get("style") == "local"]
if len(units) != 1:
    raise RuntimeError("expected exactly one local agentic main-library unit")
cases = [
    ("worker-positive", "import Agentic.Manager.Worker (FrontendWorker)\nkeep :: FrontendWorker -> FrontendWorker\nkeep = id\n", None),
    ("worker-constructor", "import Agentic.Manager.Worker\nforge :: FrontendWorker\nforge = FrontendWorker " + " ".join(["undefined"] * 14) + "\n", "Illegal term-level use of the type constructor"),
    ("worker-generic", "import Agentic.Manager.Worker (FrontendWorker)\nimport GHC.Generics (from)\ninspect :: FrontendWorker -> ()\ninspect worker = from worker `seq` ()\n", "Generic FrontendWorker"),
    ("body-positive", "import Agentic.Manager.Commands (BodyBinding)\nkeep :: BodyBinding -> BodyBinding\nkeep = id\n", None),
    ("body-constructor", "import Agentic.Manager.Commands\nforge :: BodyBinding\nforge = BodyBinding undefined undefined undefined\n", "Illegal term-level use of the type constructor"),
    ("body-generic", "import Agentic.Manager.Commands (BodyBinding)\nimport GHC.Generics (from)\ninspect :: BodyBinding -> ()\ninspect proof = from proof `seq` ()\n", "Generic BodyBinding"),
    ("positive", "import Agentic.Manager.Authorization (CredentialProof)\nkeep :: CredentialProof -> CredentialProof\nkeep = id\n", None),
    ("constructor", "import Agentic.Manager.Authorization\nforge :: CredentialProof\nforge = CredentialProof undefined undefined undefined undefined\n", "Illegal term-level use of the type constructor"),
    ("generic", "import Agentic.Manager.Authorization (CredentialProof)\nimport GHC.Generics (from)\ninspect :: CredentialProof -> ()\ninspect proof = from proof `seq` ()\n", "Generic CredentialProof"),
]
for module, token in [("Store", "CommitDeadline"), ("Admission", "Admission"), ("Admission", "LivePreparation"),
                      ("Commands", "AcceptedEnqueue"), ("Commands", "CommandAttempt")]:
    imported = f"import Agentic.Manager.{module} ({token})\n"
    cases.extend([
        (token + "-positive", imported + f"keep :: {token} -> {token}\nkeep = id\n", None),
        (token + "-constructor", f"import Agentic.Manager.{module}\nforge :: {token}\nforge = {token} `seq` undefined\n", "Illegal term-level use of the type constructor"),
        (token + "-generic", imported + f"import GHC.Generics (from)\ninspect :: {token} -> ()\ninspect value = from value `seq` ()\n", "Generic " + token),
    ])
for name, body, expected in cases:
    directory = work / name
    directory.mkdir()
    fixture = directory / "ProofConsumer.hs"
    fixture.write_text("module ProofConsumer where\n" + body)
    command = ["bash", "test/cabal.sh", "exec", "--", "ghc", "-fno-code", "-Werror",
               "-imanager/src", "-package-id", units[0], "-package", "direct-sqlite",
               "-outputdir", str(directory), str(fixture)]
    result = subprocess.run(command, cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=120)
    (directory / "compile.log").write_text(result.stdout)
    if expected is None:
        if result.returncode != 0:
            raise RuntimeError(f"positive compiler control failed: {result.stdout}")
    elif result.returncode == 0 or expected not in result.stdout:
        raise RuntimeError(f"negative compiler result was not the required opacity refusal: {result.stdout}")
    print(f"PASS real-source credential proof opacity: {name}")
