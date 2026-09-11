#!/usr/bin/env python3
"""Check the manager model and default-target coverage in an isolated model workspace."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def sources(model):
    files = [p for p in model.rglob("*.lean") if ".lake" not in p.relative_to(model).parts]
    files += [model / name for name in ("lakefile.toml", "lake-manifest.json", "lean-toolchain")]
    return {str(p.relative_to(model)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True,
                        help="isolated model source and pinned dependency workspace under ~/Products")
    parser.add_argument("--artifacts", type=Path, required=True,
                        help="parent directory for retained check logs and the negative fixture")
    args = parser.parse_args()
    products = (Path.home() / "Products").resolve()
    workspace = args.workspace.resolve(strict=True)
    artifacts = args.artifacts.resolve()
    canonical = Path(__file__).resolve().parents[1]
    if (workspace == canonical or not workspace.is_relative_to(products)
            or not artifacts.is_relative_to(products) or artifacts.is_relative_to(workspace)):
        parser.error("workspace and artifacts must be separate paths under ~/Products")
    packages = (workspace / ".lake/packages").resolve(strict=True)
    if not packages.is_relative_to(products):
        parser.error("dependency workspace must also be isolated under ~/Products")
    expected = sources(canonical)
    if sources(workspace) != expected:
        parser.error("model workspace does not match the current canonical Lean sources and configuration")
    manifest = json.loads((workspace / "lake-manifest.json").read_text())
    for package in manifest["packages"]:
        checkout = (packages / package["name"]).resolve(strict=True)
        if not checkout.is_relative_to(products) or package["type"] != "git":
            parser.error("expected isolated Git checkouts for the pinned model dependencies")
        command = ["git", "-C", str(checkout)]
        environment = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
        revision = subprocess.check_output(command + ["rev-parse", "HEAD"], env=environment, text=True).strip()
        changed = subprocess.check_output(command + ["status", "--porcelain", "--untracked-files=no"],
                                          env=environment, text=True)
        if revision != package["rev"] or changed:
            parser.error(f"dependency {package['name']} does not match its frozen source revision")
    artifacts.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="manager-model-", dir=artifacts))
    print(f"Evidence: {output}", flush=True)

    def build(model, name):
        command = ["lake", "--dir", str(model), "--no-cache", "--wfail", "build"]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (output / f"{name}.log").write_text("COMMAND: " + " ".join(command) + "\n" + result.stdout)
        return result

    baseline = build(workspace, "default-build")
    if baseline.returncode:
        raise SystemExit(baseline.stdout)
    print(baseline.stdout, end="", flush=True)

    negative = output / "model"
    shutil.copytree(workspace, negative, ignore=shutil.ignore_patterns(".lake", ".git"))
    (negative / ".lake").mkdir()
    (negative / ".lake/packages").symlink_to(packages, target_is_directory=True)
    shutil.copytree(workspace / ".lake/build", negative / ".lake/build")
    marker = "wm004-unimported-module-must-fail"
    broken = negative / "Agentic/Manager/BuildCoverage/Unimported.lean"
    broken.parent.mkdir(parents=True)
    broken.write_text(f'def managerCoverageFailure : Nat := "{marker}"\n')
    failure = build(negative, "unimported-manager-module")
    if not failure.returncode or marker not in failure.stdout or "BuildCoverage.Unimported" not in failure.stdout:
        raise SystemExit("default model build did not reject the unimported manager module:\n" + failure.stdout)

    config = negative / "lakefile.toml"
    original = config.read_text()
    if original.count(', "Agentic.Manager.+"') != 1:
        raise SystemExit("expected one explicit manager namespace glob in the model library")
    config.write_text(original.replace(', "Agentic.Manager.+"', ""))
    omitted = build(negative, "missing-glob-control")
    if omitted.returncode:
        raise SystemExit("the missing-glob control failed for an unrelated reason:\n" + omitted.stdout)
    config.write_text(original)
    broken.unlink()

    checks = negative / "test/ManagerChecks.lean"
    checks.write_text(checks.read_text() + f'\ndef managerWitnessFailure : Nat := "{marker}"\n')
    failure = build(negative, "manager-checks-target")
    if not failure.returncode or marker not in failure.stdout or "ManagerChecks" not in failure.stdout:
        raise SystemExit("default model build did not reject the broken witness/axiom target:\n" + failure.stdout)
    if sources(canonical) != expected or sources(workspace) != expected:
        raise SystemExit("canonical or positive model sources changed during negative checks")
    print("Manager model: default build passed; unimported namespace and witness errors refused; "
          "missing-glob control confirmed. Physical runtime/storage behavior remains unproved.")


if __name__ == "__main__":
    main()
